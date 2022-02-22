open Core
open Async
include Intf

module Thread = struct
  type t = { name : string; mutable elapsed : Time_ns.Span.t }
  [@@deriving sexp_of]

  let threads : t String.Table.t = String.Table.create ()

  let register name =
    match Hashtbl.find threads name with
    | Some thread ->
        thread
    | None ->
        let thread = { name; elapsed = Time_ns.Span.zero } in
        Hashtbl.set threads ~key:name ~data:thread ;
        thread

  let iter_threads ~f = Hashtbl.iter threads ~f:(fun t -> f t.name)

  let get_elapsed_time name =
    let open Option.Let_syntax in
    let%map thread = Hashtbl.find threads name in
    thread.elapsed
end

module Fiber = struct
  include Hashable.Make (struct
    type t = string list [@@deriving compare, hash, sexp]
  end)

  let next_id = ref 1

  type t = { id : int; parent : t option; thread : Thread.t }
  [@@deriving sexp_of]

  let ctx_id : t Type_equal.Id.t = Type_equal.Id.create ~name:"fiber" sexp_of_t

  let fibers : t Table.t = Table.create ()

  let rec fiber_key name parent =
    name
    :: Option.value_map parent ~default:[] ~f:(fun p ->
           fiber_key p.thread.name p.parent)

  let register name parent =
    let key = fiber_key name parent in
    match Hashtbl.find fibers key with
    | Some fiber ->
        fiber
    | None ->
        let thread = Thread.register name in
        let fiber = { id = !next_id; parent; thread } in
        incr next_id ;
        Hashtbl.set fibers ~key ~data:fiber ;
        fiber

  let apply_to_context t ctx =
    let ctx = Execution_context.with_tid ctx t.id in
    Execution_context.with_local ctx ctx_id (Some t)

  let rec record_elapsed_time span t =
    t.thread.elapsed <- Time_ns.Span.(t.thread.elapsed + span) ;
    Option.iter t.parent ~f:(record_elapsed_time span)
end

module No_trace = struct
  module Hooks = struct
    let on_job_enter _ = ()

    let on_job_exit _ _ = ()
  end

  let measure _ f = f ()

  let trace _ f = f ()

  let trace_event _ = ()

  let trace_recurring = trace

  let trace_task _ f = don't_wait_for (f ())

  let trace_recurring_task = trace_task
end

let implementation = ref (module No_trace : S_with_hooks)

let set_implementation x = implementation := x

let measure name f =
  let (module M) = !implementation in
  M.measure name f

let trace_event name =
  let (module M) = !implementation in
  M.trace_event name

let trace name f =
  let (module M) = !implementation in
  M.trace name f

let trace_recurring name f =
  let (module M) = !implementation in
  M.trace_recurring name f

let trace_recurring_task name f =
  let (module M) = !implementation in
  M.trace_recurring_task name f

let trace_task name f =
  let (module M) = !implementation in
  M.trace_task name f

let forget_tid f =
  let new_ctx =
    Execution_context.with_tid Scheduler.(current_execution_context ()) 0
  in
  let res = Scheduler.within_context new_ctx f |> Result.ok in
  Option.value_exn res

(* execution timing *)

let time_execution' (name : string) (f : unit -> 'a) =
  let thread = Thread.register name in
  let start_time = Time_ns.now () in
  let x = f () in
  let elapsed_time = Time_ns.abs_diff (Time_ns.now ()) start_time in
  thread.elapsed <- Time_ns.Span.(thread.elapsed + elapsed_time) ;
  x

let time_execution (name : string) (f : unit -> 'a) =
  let rec find_recursive_call (fiber : Fiber.t) =
    if String.equal fiber.thread.name name then Some fiber
    else Option.bind fiber.parent ~f:find_recursive_call
  in
  let ctx = Scheduler.current_execution_context () in
  let parent = Execution_context.find_local ctx Fiber.ctx_id in
  if
    Option.value_map parent ~default:false ~f:(fun p ->
        String.equal p.thread.name name)
  then f ()
  else
    let fiber =
      match Option.bind parent ~f:find_recursive_call with
      | Some fiber ->
          fiber
      | None ->
          Fiber.register name parent
    in
    let ctx = Fiber.apply_to_context fiber ctx in
    match Scheduler.within_context ctx f with
    | Error () ->
        failwithf
          "timing task `%s` failed, exception reported to parent monitor" name
          ()
    | Ok x ->
        x

(* scheduler hooks *)

let on_job_enter ctx =
  let (module M) = !implementation in
  M.Hooks.on_job_enter ctx

let on_job_exit ctx elapsed_time =
  Option.iter
    (Execution_context.find_local ctx Fiber.ctx_id)
    ~f:(Fiber.record_elapsed_time elapsed_time) ;
  let (module M) = !implementation in
  M.Hooks.on_job_exit ctx elapsed_time

let () = Async_kernel.Tracing.fns := { on_job_enter; on_job_exit }

(* FUTURE: migrate to `thread` and `label` based api, with dynamic multidispatch for tracing subsystems *)
