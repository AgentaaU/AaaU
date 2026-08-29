(** Creator-side execution of a single editor request. *)

val handle_request :
  ?timeout:float -> command:(string * string list) -> Editor_protocol.request ->
  Editor_protocol.response Lwt.t
(** Create a private random temporary, execute the configured editor directly
    with [-- PATH] (emacsclient waits by default), return edited bytes on
    success, and always unlink. *)
