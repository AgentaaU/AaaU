(** Client-side socket helpers shared by the CLI and tests. *)

val write_all : Lwt_unix.file_descr -> string -> unit Lwt.t
(** Write the full string to the socket, handling partial writes. *)

val split_handshake_response : string -> string * string
(** Split a handshake response into the first line and trailing output bytes. *)

type handshake_result =
  | Timeout
  | Response of string * string

val read_handshake_response :
  ?timeout:float ->
  Lwt_unix.file_descr ->
  handshake_result Lwt.t
(** Read the initial handshake response and any trailing output received in
    the same socket read. *)
