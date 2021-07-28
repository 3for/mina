(*
 * This file has been generated by the OCamlClientCodegen generator for openapi-generator.
 *
 * Generated by: https://openapi-generator.tech
 *
 * Schema Block_response.t : A BlockResponse includes a fully-populated block or a partially-populated block with a list of other transactions to fetch (other_transactions). As a result of the consensus algorithm of some blockchains, blocks can be omitted (i.e. certain block indices can be skipped). If a query for one of these omitted indices is made, the response should not include a `Block` object. It is VERY important to note that blocks MUST still form a canonical, connected chain of blocks where each block has a unique index. In other words, the `PartialBlockIdentifier` of a block after an omitted block should reference the last non-omitted block.
 *)

type t =
  { block : Block.t option [@default None]
  ; (* Some blockchains may require additional transactions to be fetched that weren't returned in the block response (ex: block only returns transaction hashes). For blockchains with a lot of transactions in each block, this can be very useful as consumers can concurrently fetch all transactions returned. *)
    other_transactions : Transaction_identifier.t list
  }
[@@deriving yojson { strict = false }, show]

(** A BlockResponse includes a fully-populated block or a partially-populated block with a list of other transactions to fetch (other_transactions). As a result of the consensus algorithm of some blockchains, blocks can be omitted (i.e. certain block indices can be skipped). If a query for one of these omitted indices is made, the response should not include a `Block` object. It is VERY important to note that blocks MUST still form a canonical, connected chain of blocks where each block has a unique index. In other words, the `PartialBlockIdentifier` of a block after an omitted block should reference the last non-omitted block. *)
let create () : t = { block = None; other_transactions = [] }
