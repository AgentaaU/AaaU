(** Safe agent-buffer and provider-temporary-file operations. *)

type source
type temporary

val open_source : path:string -> owner_uid:int -> (source, string) result
(** Open exactly one regular, owner-matching file with [O_NOFOLLOW], retaining
    the descriptor to prevent path replacement races. *)
val read_source : source -> (string, string) result
val write_source : source -> string -> (unit, string) result
val apply_response : source -> Editor_protocol.response -> int * string option
(** Copy back only a successful response containing valid bounded content. *)
val close_source : source -> unit

val create_temporary : content:string -> (temporary, string) result
(** Atomically create an unpredictable mode-0600 file below [/tmp]. *)
val temporary_path : temporary -> string
val read_temporary : temporary -> (string, string) result
val cleanup_temporary : temporary -> unit
