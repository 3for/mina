(*
 * This file has been generated by the OCamlClientCodegen generator for openapi-generator.
 *
 * Generated by: https://openapi-generator.tech
 *
 * Schema Block.t : Blocks contain an array of Transactions that occurred at a particular BlockIdentifier. A hard requirement for blocks returned by Rosetta implementations is that they MUST be _inalterable_: once a client has requested and received a block identified by a specific BlockIndentifier, all future calls for that same BlockIdentifier must return the same block contents.
 *)

type t =
  { block_identifier : Block_identifier.t
  ; parent_block_identifier : Block_identifier.t
  ; (* The timestamp of the block in milliseconds since the Unix Epoch. The timestamp is stored in milliseconds because some blockchains produce blocks more often than once a second. *)
    timestamp : int64
  ; transactions : Transaction.t list
  ; metadata : Yojson.Safe.t option [@default None]
  }
[@@deriving yojson { strict = false }, show]

(** Blocks contain an array of Transactions that occurred at a particular BlockIdentifier. A hard requirement for blocks returned by Rosetta implementations is that they MUST be _inalterable_: once a client has requested and received a block identified by a specific BlockIndentifier, all future calls for that same BlockIdentifier must return the same block contents. *)
let create (block_identifier : Block_identifier.t)
    (parent_block_identifier : Block_identifier.t) (timestamp : int64)
    (transactions : Transaction.t list) : t =
  { block_identifier
  ; parent_block_identifier
  ; timestamp
  ; transactions
  ; metadata = None
  }
