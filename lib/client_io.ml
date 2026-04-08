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

type line_result =
  | End_of_file
  | Line of string * string
  | Timeout_line

let read_line_with_remainder ?timeout ?(max_length=65536) socket =
  let rec loop acc =
    if String.length acc > max_length then
      Lwt.fail_with "Handshake line too long"
    else
      match String.index_opt acc '\n' with
      | Some idx ->
        let line = String.sub acc 0 idx in
        let remaining_len = String.length acc - idx - 1 in
        let remaining =
          if remaining_len > 0 then
            String.sub acc (idx + 1) remaining_len
          else
            ""
        in
        Lwt.return (Line (String.trim line, remaining))
      | None ->
        let buf = Bytes.create 4096 in
        let read_op =
          let* n = Lwt_unix.read socket buf 0 4096 in
          if n = 0 then
            if acc = "" then
              Lwt.return End_of_file
            else
              Lwt.return (Line (String.trim acc, ""))
          else
            loop (acc ^ Bytes.sub_string buf 0 n)
        in
        match timeout with
        | None -> read_op
        | Some timeout_s ->
          Lwt.pick [
            read_op;
            (let* () = Lwt_unix.sleep timeout_s in
             Lwt.return Timeout_line);
          ]
  in
  loop ""

type handshake_result =
  | Timeout
  | Response of string * string

let read_handshake_response ?(timeout=5.0) socket =
  let* result = read_line_with_remainder ~timeout socket in
  match result with
  | Timeout_line -> Lwt.return Timeout
  | End_of_file -> Lwt.return (Response ("", ""))
  | Line (handshake_line, initial_output) ->
    Lwt.return (Response (handshake_line, initial_output))
