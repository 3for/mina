(*
 * This file has been generated by the OCamlClientCodegen generator for openapi-generator.
 *
 * Generated by: https://openapi-generator.tech
 *
 * Schema Operation_identifier.t : The operation_identifier uniquely identifies an operation within a transaction.
 *)

type t =
  { (* The operation index is used to ensure each operation has a unique identifier within a transaction. This index is only relative to the transaction and NOT GLOBAL. The operations in each transaction should start from index 0. To clarify, there may not be any notion of an operation index in the blockchain being described. *)
    index : int64
  ; (* Some blockchains specify an operation index that is essential for client use. For example, Bitcoin uses a network_index to identify which UTXO was used in a transaction. network_index should not be populated if there is no notion of an operation index in a blockchain (typically most account-based blockchains). *)
    network_index : int64 option [@default None]
  }
[@@deriving yojson { strict = false }, show]

(** The operation_identifier uniquely identifies an operation within a transaction. *)
let create (index : int64) : t = { index; network_index = None }
