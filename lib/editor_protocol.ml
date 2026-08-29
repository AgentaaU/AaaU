open Lwt.Syntax

let max_buffer_size = 1024 * 1024
let max_payload = (2 * 1024 * 1024) + 4096
let request_timeout_seconds = 300.0

type request = { request_id : string; content : string }
type response = { request_id : string; status : int; error : string option; content : string option }

let hex_digit value = "0123456789abcdef".[value land 0xf]
let hex_encode value =
  let output = Bytes.create (String.length value * 2) in
  String.iteri (fun index character ->
    let byte = Char.code character in
    Bytes.set output (index * 2) (hex_digit (byte lsr 4));
    Bytes.set output ((index * 2) + 1) (hex_digit byte)) value;
  Bytes.unsafe_to_string output

let hex_value = function
  | '0' .. '9' as c -> Some (Char.code c - Char.code '0')
  | 'a' .. 'f' as c -> Some (10 + Char.code c - Char.code 'a')
  | 'A' .. 'F' as c -> Some (10 + Char.code c - Char.code 'A')
  | _ -> None

let hex_decode value =
  if String.length value mod 2 <> 0 || String.length value / 2 > max_buffer_size then Error "Invalid editor content"
  else
    let output = Bytes.create (String.length value / 2) in
    let rec loop index =
      if index = Bytes.length output then Ok (Bytes.unsafe_to_string output)
      else match hex_value value.[index * 2], hex_value value.[index * 2 + 1] with
        | Some high, Some low -> Bytes.set_uint8 output index ((high lsl 4) lor low); loop (index + 1)
        | _ -> Error "Invalid editor content"
    in loop 0

let request_to_string (request : request) =
  `Assoc ["request_id", `String request.request_id; "content_hex", `String (hex_encode request.content)]
  |> Yojson.Safe.to_string

let response_to_string (response : response) =
  `Assoc (["request_id", `String response.request_id; "status", `Int response.status]
          @ (match response.error with None -> [] | Some error -> ["error", `String error])
          @ (match response.content with None -> [] | Some content -> ["content_hex", `String (hex_encode content)]))
  |> Yojson.Safe.to_string

let string_field key fields = match List.assoc_opt key fields with
  | Some (`String value) -> Ok value | _ -> Error ("Invalid " ^ key)

let request_of_string payload =
  try match Yojson.Safe.from_string payload with
    | `Assoc fields ->
      begin match string_field "request_id" fields, string_field "content_hex" fields with
      | Ok request_id, Ok encoded when request_id <> "" ->
        Result.map (fun content -> { request_id; content }) (hex_decode encoded)
      | Error message, _ | _, Error message -> Error message
      | _ -> Error "Invalid request ID"
      end
    | _ -> Error "Editor request must be an object"
  with Yojson.Json_error message -> Error ("Invalid editor JSON: " ^ message)

let response_of_string payload =
  try match Yojson.Safe.from_string payload with
    | `Assoc fields ->
      begin match string_field "request_id" fields, List.assoc_opt "status" fields with
      | Ok request_id, Some (`Int status) when request_id <> "" && status >= 0 && status <= 255 ->
        let error = match List.assoc_opt "error" fields with
          | None -> Ok None
          | Some (`String value) when String.length value <= 4096 -> Ok (Some value)
          | _ -> Error "Invalid error"
        in
        let content = match List.assoc_opt "content_hex" fields with
          | None -> Ok None
          | Some (`String value) -> Result.map Option.some (hex_decode value)
          | _ -> Error "Invalid editor content"
        in
        begin match error, content with
        | Ok error, Ok content -> Ok { request_id; status; error; content }
        | Error message, _ | _, Error message -> Error message
        end
      | Error message, _ -> Error message
      | _ -> Error "Invalid status"
      end
    | _ -> Error "Editor response must be an object"
  with Yojson.Json_error message -> Error ("Invalid editor JSON: " ^ message)

let frame payload =
  let length = String.length payload in
  if length > max_payload then Error "Editor payload exceeds limit"
  else
    let header = Bytes.create 4 in
    Bytes.set_uint8 header 0 ((length lsr 24) land 0xff);
    Bytes.set_uint8 header 1 ((length lsr 16) land 0xff);
    Bytes.set_uint8 header 2 ((length lsr 8) land 0xff);
    Bytes.set_uint8 header 3 (length land 0xff);
    Ok (Bytes.unsafe_to_string header ^ payload)

let write_all fd data =
  let rec loop offset =
    if offset = String.length data then Lwt.return_ok ()
    else let* written = Lwt_unix.write_string fd data offset (String.length data - offset) in
      if written = 0 then Lwt.return_error "Editor connection closed" else loop (offset + written)
  in Lwt.catch (fun () -> loop 0) (fun exn -> Lwt.return_error (Printexc.to_string exn))

let write_frame fd payload = match frame payload with
  | Error _ as error -> Lwt.return error | Ok data -> write_all fd data

let read_exact fd length =
  let buffer = Bytes.create length in
  let rec loop offset =
    if offset = length then Lwt.return_ok (Bytes.unsafe_to_string buffer)
    else let* count = Lwt_unix.read fd buffer offset (length - offset) in
      if count = 0 then Lwt.return_error "Editor connection closed" else loop (offset + count)
  in Lwt.catch (fun () -> loop 0) (fun exn -> Lwt.return_error (Printexc.to_string exn))

let read_frame ?timeout fd =
  let read =
    let* header = read_exact fd 4 in
    match header with
    | Error _ as error -> Lwt.return error
    | Ok header ->
      let byte index = Char.code header.[index] in
      let length = (byte 0 lsl 24) lor (byte 1 lsl 16) lor (byte 2 lsl 8) lor byte 3 in
      if length > max_payload then Lwt.return_error "Editor payload exceeds limit" else read_exact fd length
  in
  match timeout with
  | None -> read
  | Some seconds ->
    Lwt.pick [read; (let* () = Lwt_unix.sleep seconds in Lwt.return_error "Editor frame timed out")]
