(** Bounded protocol for transferring one editor buffer. *)

val max_buffer_size : int
val max_payload : int
val request_timeout_seconds : float

type request = { request_id : string; content : string }
type response = {
  request_id : string;
  status : int;
  error : string option;
  content : string option;
}

val request_to_string : request -> string
val request_of_string : string -> (request, string) result
val response_to_string : response -> string
val response_of_string : string -> (response, string) result
val frame : string -> (string, string) result
val write_frame : Lwt_unix.file_descr -> string -> (unit, string) result Lwt.t
val read_frame : ?timeout:float -> Lwt_unix.file_descr -> (string, string) result Lwt.t
