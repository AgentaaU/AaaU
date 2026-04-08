(** Client-side socket helpers shared by the CLI and tests. *)

val write_all : Lwt_unix.file_descr -> string -> unit Lwt.t
(** Write the full string to the socket, handling partial writes. *)

val split_handshake_response : string -> string * string
(** Split a handshake response into the first line and trailing output bytes. *)

type line_result =
  | End_of_file
  | Line of string * string
  | Timeout_line

val read_line_with_remainder :
  ?timeout:float ->
  ?max_length:int ->
  Lwt_unix.file_descr ->
  line_result Lwt.t
(** Read from a socket until a newline is received, returning the line without
    the newline and any trailing bytes already received. *)

type handshake_result =
  | Timeout
  | Response of string * string

val read_handshake_response :
  ?timeout:float ->
  Lwt_unix.file_descr ->
  handshake_result Lwt.t
(** Read the initial handshake response and any trailing output received in
    the same socket read. *)
