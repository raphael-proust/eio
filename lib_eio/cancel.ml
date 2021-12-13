open EffectHandlers

exception Cancel_hook_failed of exn list

exception Cancelled of exn

let () =
  Printexc.register_printer @@ function
  | Cancel_hook_failed exns -> Some ("During cancellation:\n" ^ String.concat "\nand\n" (List.map Printexc.to_string exns))
  | Cancelled ex -> Some ("Cancelled: " ^ Printexc.to_string ex)
  | _ -> None

type state =
  | On
  | Cancelling of exn * Printexc.raw_backtrace
  | Finished

(* There is a tree of cancellation contexts for each domain.
   A fibre is always in exactly one context, but can move to a new child and back (see [sub]).
   While a fibre is performing a cancellable operation, it sets a cancel function.
   When a context is cancelled, we attempt to call and remove each fibre's cancellation function, if any.
   Cancelling always happens from the fibre's own domain, but the cancellation function may be removed
   from another domain as soon as an operation is known to have succeeded.
   An operation may either finish normally or be cancelled;
   whoever manages to clear the cancellation function is responsible for resuming the continuation.
   If cancelled, this is done by calling the cancellation function. *)
type t = {
  mutable state : state;
  parent : t;
  children : t Lwt_dllist.t;
  fibres : fibre_context Lwt_dllist.t;
  protected : bool;
}
and fibre_context = {
  tid : Ctf.id;
  mutable cancel_context : t;
  mutable cancel_node : fibre_context Lwt_dllist.node option; (* Our entry in [cancel_context.fibres] *)
  cancel_fn : (exn -> unit) option Atomic.t;
}

(* A dummy value for bootstrapping *)
let rec boot = {
  state = Finished;
  parent = boot;
  children = Lwt_dllist.create ();
  fibres = Lwt_dllist.create ();
  protected = false;
}

type _ eff += Get_context : fibre_context eff

let cancelled t =
  match t.state with
  | On -> false
  | Cancelling _ -> true
  | Finished -> invalid_arg "Cancellation context finished!"

let check t =
  match t.state with
  | On -> ()
  | Cancelling (ex, _) -> raise (Cancelled ex)
  | Finished -> invalid_arg "Cancellation context finished!"

let get_error t =
  match t.state with
  | On -> None
  | Cancelling (ex, _) -> Some (Cancelled ex)
  | Finished -> Some (Invalid_argument "Cancellation context finished!")

let is_finished t =
  match t.state with
  | Finished -> true
  | On | Cancelling _ -> false

let move_fibre_to t fibre =
  let new_node = Lwt_dllist.add_r fibre t.fibres in     (* Add to new context *)
  fibre.cancel_context <- t;
  Option.iter Lwt_dllist.remove fibre.cancel_node;      (* Remove from old context *)
  fibre.cancel_node <- Some new_node

(* Runs [fn] with a fresh cancellation context. *)
let with_cc ~ctx:fibre ~parent ~protected fn =
  let children = Lwt_dllist.create () in
  let fibres = Lwt_dllist.create () in
  let t = { state = On; parent; children; protected; fibres } in
  let node = Lwt_dllist.add_r t parent.children in
  move_fibre_to t fibre;
  let cleanup () =
    move_fibre_to parent fibre;
    t.state <- Finished;
    Lwt_dllist.remove node
  in
  match fn t with
  | x            -> cleanup (); x
  | exception ex -> cleanup (); raise ex

let protect fn =
  let ctx = perform Get_context in
  with_cc ~ctx ~parent:ctx.cancel_context ~protected:true @@ fun t ->
  let x = fn () in
  check t;
  x

let rec cancel t ex =
  match t.state with
  | Finished -> invalid_arg "Cancellation context finished!"
  | Cancelling _ -> ()
  | On ->
    let bt = Printexc.get_raw_backtrace () in
    t.state <- Cancelling (ex, bt);
    let cex = Cancelled ex in
    let rec aux () =
      match Lwt_dllist.take_opt_r t.fibres with
      | None -> Lwt_dllist.fold_r (cancel_child ex) t.children []
      | Some fibre ->
        match Atomic.exchange fibre.cancel_fn None with
        | None -> aux ()        (* The operation succeeded and so can't be cancelled now *)
        | Some cancel_fn ->
          match cancel_fn cex with
          | () -> aux ()
          | exception ex2 -> ex2 :: aux ()
    in
    match protect aux with
    | [] -> ()
    | exns -> raise (Cancel_hook_failed exns)
and cancel_child ex t acc =
  if t.protected then acc
  else match cancel t ex with
    | () -> acc
    | exception ex -> ex :: acc

let sub fn =
  let ctx = perform Get_context in
  with_cc ~ctx ~parent:ctx.cancel_context ~protected:false @@ fun t ->
  let x =
    match fn t with
    | x ->
      check t.parent;
      x
    | exception ex ->
      check t.parent;
      raise ex
  in
  match t.state with
  | On -> x
  | Cancelling (ex, bt) -> Printexc.raise_with_backtrace ex bt
  | Finished -> invalid_arg "Cancellation context finished!"

(* Like [sub], but it's OK if the new context is cancelled.
   (instead, return the parent context on exit so the caller can check that) *)
let sub_unchecked fn =
  let ctx = perform Get_context in
  with_cc ~ctx ~parent:ctx.cancel_context ~protected:false @@ fun t ->
  fn t;
  t.parent

module Fibre_context = struct
  type t = fibre_context

  let tid t = t.tid
  let cancellation_context t = t.cancel_context

  let get_error t = get_error t.cancel_context

  let set_cancel_fn t fn =
    (* if Atomic.exchange t.cancel_fn (Some fn) <> None then failwith "Fibre already has a cancel function!" *)
    Atomic.set t.cancel_fn (Some fn)

  let clear_cancel_fn t =
    Atomic.exchange t.cancel_fn None <> None

  let make ~tid ~cc =
    let t = { tid; cancel_context = cc; cancel_node = None; cancel_fn = Atomic.make None } in
    t.cancel_node <- Some (Lwt_dllist.add_r t cc.fibres);
    t

  let destroy t =
    Option.iter Lwt_dllist.remove t.cancel_node
end