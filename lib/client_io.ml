(** Client-side socket helpers shared by the CLI and tests. *)

open Lwt.Syntax

let rec write_all socket data =
  let len = String.length data in
  if len = 0 then
    Lwt.return_unit
  else
    let* written = Lwt_unix.write_string socket data 0 len in
    if written < len then
      write_all socket (String.sub data written (len - written))
    else
      Lwt.return_unit

let split_handshake_response response =
  match String.index_opt response '\n' with
  | None -> (String.trim response, "")
  | Some idx ->
    let line = String.sub response 0 idx |> String.trim in
    let remaining_len = String.length response - idx - 1 in
    let remaining =
      if remaining_len > 0 then
        String.sub response (idx + 1) remaining_len
      else
        ""
    in
    (line, remaining)

type handshake_result =
  | Timeout
  | Response of string * string

let read_handshake_response ?(timeout=5.0) socket =
  let buf = Bytes.create 1024 in
  Lwt.pick [
    (let* n = Lwt_unix.read socket buf 0 1024 in
     let response = Bytes.sub_string buf 0 n in
     let handshake_line, initial_output = split_handshake_response response in
     Lwt.return (Response (handshake_line, initial_output)));
    (let* () = Lwt_unix.sleep timeout in
     Lwt.return Timeout);
  ]
