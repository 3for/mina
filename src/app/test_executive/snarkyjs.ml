open Core
open Async
open Integration_test_lib

module Make (Inputs : Intf.Test.Inputs_intf) = struct
  open Inputs
  open Engine
  open Dsl

  open Test_common.Make (Inputs)

  type network = Network.t

  type node = Network.Node.t

  type dsl = Dsl.t

  let initial_balance = Currency.Balance.of_string "80000000000"

  let config =
    let open Test_config in
    let open Test_config.Block_producer in
    { default with
      requires_graphql = true
    ; block_producers =
        [ { balance = Currency.Balance.to_string initial_balance
          ; timing = Untimed
          }
        ]
    ; num_snark_workers = 0
    }

  let run network t =
    let open Malleable_error.Let_syntax in
    let logger = Logger.create () in
    let wait_for_zkapp parties =
      let with_timeout =
        let soft_slots = 3 in
        let soft_timeout = Network_time_span.Slots soft_slots in
        let hard_timeout = Network_time_span.Slots (soft_slots * 2) in
        Wait_condition.with_timeouts ~soft_timeout ~hard_timeout
      in
      let%map () =
        wait_for t @@ with_timeout
        @@ Wait_condition.snapp_to_be_included_in_frontier ~parties
      in
      [%log info] "Snapps transaction included in transition frontier"
    in
    let block_producer_nodes = Network.block_producers network in
    let node = List.hd_exn block_producer_nodes in
    let%bind my_pk = Util.pub_key_of_node node in
    let%bind my_sk = Util.priv_key_of_node node in
    let my_account_id =
      Mina_base.Account_id.create my_pk Mina_base.Token_id.default
    in
    (* concurrently make/sign the deploy transaction and wait for the node to be ready *)
    let%bind.Deferred parties_deploy_contract, unit_with_error =
      Deferred.both
        ((fun _my_sk ->
           failwith
             "TODO: shell exec to make/sign the deploy transaction with \
              keypair for paying fees")
           (Signature_lib.Private_key.to_base58_check my_sk))
        (wait_for t (Wait_condition.node_to_initialize node))
    in
    let%bind () = Deferred.return unit_with_error in
    (* Note: Sending the snapp "outside OCaml" so we can _properly_ ensure that the GraphQL API is working *)
    let () = failwith "TODO: shell exec to send signed transaction" in
    let%bind () =
      section
        "Wait for smart contract transaction to be included in transition \
         frontier"
        (wait_for_zkapp parties_deploy_contract)
    in
    let%bind manipulation_of_contract_transaction =
      failwith
        "TODO: shell exec to make/sign+send the user manipulation transction \
         (+ keypair as the user)"
    in
    let%bind () =
      section
        "Wait for manipulation transaction to be included in transition \
         frontier"
        (wait_for_zkapp manipulation_of_contract_transaction)
    in
    let%bind () =
      section "Verify that the manipulation transaction did update the ledger"
        ( [%log info] "Verifying permissions for account"
            ~metadata:
              [ ("account_id", Mina_base.Account_id.to_yojson my_account_id) ] ;
          let%bind balance = get_account_balance ~logger node my_account_id in
          if
            Currency.Balance.(
              equal balance
                ( initial_balance - Currency.Amount.of_string "10000000000"
                |> Option.value_exn ))
          then (
            [%log info] "Ledger sees balance change from zkapp execution" ;
            return () )
          else (
            [%log error]
              "Ledger does not see balance change from zkapp execution (-10 \
               MINA from initial_balance)"
              ~metadata:
                [ ("balance", Currency.Balance.to_yojson balance)
                ; ("initial_balance", Currency.Balance.to_yojson initial_balance)
                ] ;
            Malleable_error.hard_error
              (Error.of_string
                 "Balance changes not witnessed from smart contract execution")
            ) )
    in
    return ()
end