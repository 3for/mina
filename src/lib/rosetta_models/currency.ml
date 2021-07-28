(*
 * This file has been generated by the OCamlClientCodegen generator for openapi-generator.
 *
 * Generated by: https://openapi-generator.tech
 *
 * Schema Currency.t : Currency is composed of a canonical Symbol and Decimals. This Decimals value is used to convert an Amount.Value from atomic units (Satoshis) to standard units (Bitcoins).
 *)

type t =
  { (* Canonical symbol associated with a currency. *)
    symbol : string
  ; (* Number of decimal places in the standard unit representation of the amount. For example, BTC has 8 decimals. Note that it is not possible to represent the value of some currency in atomic units that is not base 10. *)
    decimals : int32
  ; (* Any additional information related to the currency itself. For example, it would be useful to populate this object with the contract address of an ERC-20 token. *)
    metadata : Yojson.Safe.t option [@default None]
  }
[@@deriving yojson { strict = false }, show]

(** Currency is composed of a canonical Symbol and Decimals. This Decimals value is used to convert an Amount.Value from atomic units (Satoshis) to standard units (Bitcoins). *)
let create (symbol : string) (decimals : int32) : t =
  { symbol; decimals; metadata = None }
