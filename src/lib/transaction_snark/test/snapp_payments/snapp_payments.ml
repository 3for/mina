open Core
open Mina_ledger
open Currency
open Snark_params
open Tick
module U = Transaction_snark_tests.Util
module Spec = Transaction_snark.For_tests.Spec
open Mina_base

let%test_module "Snapp payments tests" =
  ( module struct
    let memo = Signed_command_memo.create_from_string_exn "Snapp payments tests"

    let merkle_root_after_parties_exn t ~txn_state_view txn =
      let hash =
        Ledger.merkle_root_after_parties_exn
          ~constraint_constants:U.constraint_constants ~txn_state_view t txn
      in
      Frozen_ledger_hash.of_ledger_hash hash

    let signed_signed ~(wallets : U.Wallet.t array) i j : Parties.t =
      let full_amount = 8_000_000_000 in
      let fee = Fee.of_int (Random.int full_amount) in
      let receiver_amount =
        Amount.sub (Amount.of_int full_amount) (Amount.of_fee fee)
        |> Option.value_exn
      in
      let acct1 = wallets.(i) in
      let acct2 = wallets.(j) in
      let new_state : _ Snapp_state.V.t =
        Pickles_types.Vector.init Snapp_state.Max_state_size.n ~f:Field.of_int
      in
      { fee_payer =
          { Party.Fee_payer.data =
              { body =
                  { public_key = acct1.account.public_key
                  ; update =
                      { app_state =
                          Pickles_types.Vector.map new_state ~f:(fun x ->
                              Snapp_basic.Set_or_keep.Set x)
                      ; delegate = Keep
                      ; verification_key = Keep
                      ; permissions = Keep
                      ; snapp_uri = Keep
                      ; token_symbol = Keep
                      ; timing = Keep
                      ; voting_for = Keep
                      }
                  ; token_id = ()
                  ; balance_change = Fee.of_int full_amount
                  ; increment_nonce = ()
                  ; events = []
                  ; sequence_events = []
                  ; call_data = Field.zero
                  ; call_depth = 0
                  ; protocol_state = Snapp_predicate.Protocol_state.accept
                  ; use_full_commitment = ()
                  }
              ; predicate = acct1.account.nonce
              }
          ; authorization = Signature.dummy
          }
      ; other_parties =
          [ { data =
                { body =
                    { public_key = acct1.account.public_key
                    ; update = Party.Update.noop
                    ; token_id = Token_id.default
                    ; balance_change =
                        Amount.Signed.(of_unsigned receiver_amount |> negate)
                    ; increment_nonce = true
                    ; events = []
                    ; sequence_events = []
                    ; call_data = Field.zero
                    ; call_depth = 0
                    ; protocol_state = Snapp_predicate.Protocol_state.accept
                    ; use_full_commitment = false
                    }
                ; predicate = Accept
                }
            ; authorization = Signature Signature.dummy
            }
          ; { data =
                { body =
                    { public_key = acct2.account.public_key
                    ; update = Party.Update.noop
                    ; token_id = Token_id.default
                    ; balance_change =
                        Amount.Signed.(of_unsigned receiver_amount)
                    ; increment_nonce = false
                    ; events = []
                    ; sequence_events = []
                    ; call_data = Field.zero
                    ; call_depth = 0
                    ; protocol_state = Snapp_predicate.Protocol_state.accept
                    ; use_full_commitment = false
                    }
                ; predicate = Accept
                }
            ; authorization = None_given
            }
          ]
      ; memo
      }

    let%test_unit "merkle_root_after_snapp_command_exn_immutable" =
      Test_util.with_randomness 123456789 (fun () ->
          let wallets = U.Wallet.random_wallets () in
          Ledger.with_ledger ~depth:U.ledger_depth ~f:(fun ledger ->
              Array.iter
                (Array.sub wallets ~pos:1 ~len:(Array.length wallets - 1))
                ~f:(fun { account; private_key = _ } ->
                  Ledger.create_new_account_exn ledger
                    (Account.identifier account)
                    account) ;
              let t1 =
                let i, j = (1, 2) in
                signed_signed ~wallets i j
              in
              let hash_pre = Ledger.merkle_root ledger in
              let _target =
                let txn_state_view =
                  Mina_state.Protocol_state.Body.view U.genesis_state_body
                in
                merkle_root_after_parties_exn ledger ~txn_state_view t1
              in
              let hash_post = Ledger.merkle_root ledger in
              [%test_eq: Field.t] hash_pre hash_post))

    let%test_unit "snapps-based payment" =
      let open Mina_transaction_logic.For_tests in
      Quickcheck.test ~trials:2 Test_spec.gen ~f:(fun { init_ledger; specs } ->
          Ledger.with_ledger ~depth:U.ledger_depth ~f:(fun ledger ->
              let parties = party_send (List.hd_exn specs) in
              Init_ledger.init (module Ledger.Ledger_inner) init_ledger ledger ;
              U.apply_parties ledger [ parties ])
          |> fun _ -> ())

    let%test_unit "Consecutive snapps-based payments" =
      let open Mina_transaction_logic.For_tests in
      Quickcheck.test ~trials:2 Test_spec.gen ~f:(fun { init_ledger; specs } ->
          Ledger.with_ledger ~depth:U.ledger_depth ~f:(fun ledger ->
              let partiess =
                List.map
                  ~f:(fun s ->
                    let use_full_commitment =
                      Quickcheck.random_value Bool.quickcheck_generator
                    in
                    party_send ~use_full_commitment s)
                  specs
              in
              Init_ledger.init (module Ledger.Ledger_inner) init_ledger ledger ;
              U.apply_parties ledger partiess |> fun _ -> ()))

    let%test_unit "multiple transfers from one account" =
      let open Mina_transaction_logic.For_tests in
      Quickcheck.test ~trials:1 U.gen_snapp_ledger
        ~f:(fun ({ init_ledger; specs }, new_kp) ->
          Ledger.with_ledger ~depth:U.ledger_depth ~f:(fun ledger ->
              Async.Thread_safe.block_on_async_exn (fun () ->
                  let fee = Fee.of_int 1_000_000 in
                  let amount = Amount.of_int 1_000_000_000 in
                  let spec = List.hd_exn specs in
                  let receiver_count = 3 in
                  let new_receiver =
                    Signature_lib.Public_key.compress new_kp.public_key
                  in
                  let test_spec : Spec.t =
                    { sender = spec.sender
                    ; fee
                    ; receivers =
                        (new_receiver, amount)
                        :: ( List.take specs (receiver_count - 1)
                           |> List.map ~f:(fun s -> (s.receiver, amount)) )
                    ; amount
                    ; snapp_account_keypairs = []
                    ; memo
                    ; new_snapp_account = false
                    ; snapp_update = Party.Update.dummy
                    ; current_auth = Permissions.Auth_required.Signature
                    ; call_data = Snark_params.Tick.Field.zero
                    ; events = []
                    ; sequence_events = []
                    }
                  in
                  let parties =
                    Transaction_snark.For_tests.multiple_transfers test_spec
                  in
                  Init_ledger.init
                    (module Ledger.Ledger_inner)
                    init_ledger ledger ;
                  U.apply_parties_with_merges ledger [ parties ])))
  end )
