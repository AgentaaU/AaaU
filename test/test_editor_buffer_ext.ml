(* Additional coverage for safe editor buffer file handling. *)

let fail fmt = Printf.ksprintf failwith fmt
let expect condition message = if not condition then failwith message

let write path content =
  let channel = open_out_bin path in
  output_string channel content;
  close_out channel

let read path =
  let channel = open_in_bin path in
  let length = in_channel_length channel in
  let value = really_input_string channel length in
  close_in channel;
  value

let with_temp f =
  let path = Filename.temp_file "aaau-buffer-ext-" ".txt" in
  Fun.protect ~finally:(fun () -> try Unix.unlink path with _ -> ()) (fun () -> f path)

let test_invalid_open () =
  let uid = Unix.getuid () in
  List.iter
    (fun path ->
      match AaaU.Editor_buffer.open_source ~path ~owner_uid:uid with
      | Error _ -> ()
      | Ok _ -> fail "invalid path accepted: %S" path)
    [ ""; "-option"; "abc\000def" ];
  match AaaU.Editor_buffer.open_source ~path:"/tmp" ~owner_uid:uid with
  | Error _ -> ()
  | Ok _ -> fail "directory accepted as an editor buffer"

let test_owner_check path =
  write path "owned";
  let uid = Unix.getuid () in
  (match AaaU.Editor_buffer.open_source ~path ~owner_uid:(uid + 1) with
  | Error message ->
    expect
      (String.starts_with ~prefix:"Editor buffer must be owned" message)
      (Printf.sprintf "unexpected owner error: %s" message)
  | Ok _ -> fail "wrong owner accepted");
  match AaaU.Editor_buffer.open_source ~path ~owner_uid:uid with
  | Error message -> fail "valid source rejected: %s" message
  | Ok source ->
    (match AaaU.Editor_buffer.write_source source "new content" with
    | Ok () -> ()
    | Error message -> fail "write_source failed: %s" message);
    (match AaaU.Editor_buffer.read_source source with
    | Ok "new content" -> ()
    | _ -> fail "write_source did not persist");
    (match
       AaaU.Editor_buffer.write_source source
         (String.make (AaaU.Editor_protocol.max_buffer_size + 1) 'x')
     with
    | Error _ -> ()
    | Ok () -> fail "oversized write_source succeeded");
    AaaU.Editor_buffer.close_source source;
    (match AaaU.Editor_buffer.read_source source with
    | Error _ -> ()
    | Ok _ -> fail "read_source succeeded after close");
    (match AaaU.Editor_buffer.write_source source "again" with
    | Error _ -> ()
    | Ok () -> fail "write_source succeeded after close")

let test_apply_response path =
  write path "original";
  let uid = Unix.getuid () in
  match AaaU.Editor_buffer.open_source ~path ~owner_uid:uid with
  | Error message -> fail "open_source failed: %s" message
  | Ok source ->
    let missing =
      { AaaU.Editor_protocol.request_id = "missing"; status = 0; error = None; content = None }
    in
    let status, message = AaaU.Editor_buffer.apply_response source missing in
    expect (status = 74) "missing content status";
    expect (message = Some "Editor provider returned no edited buffer") "missing content message";
    let oversized =
      {
        AaaU.Editor_protocol.request_id = "big";
        status = 0;
        error = None;
        content = Some (String.make (AaaU.Editor_protocol.max_buffer_size + 1) 'y');
      }
    in
    let status, _ = AaaU.Editor_buffer.apply_response source oversized in
    expect (status = 74) "oversized apply_response status";
    let success =
      { AaaU.Editor_protocol.request_id = "ok"; status = 0; error = None; content = Some "kept" }
    in
    let status, message = AaaU.Editor_buffer.apply_response source success in
    expect (status = 0) "successful apply_response status";
    expect (message = None) "successful apply_response message";
    expect (read path = "kept") "edited content was not written";
    AaaU.Editor_buffer.close_source source

let test_temporary () =
  (match AaaU.Editor_buffer.create_temporary ~content:(String.make (AaaU.Editor_protocol.max_buffer_size + 1) 'z') with
  | Error _ -> ()
  | Ok temporary ->
    AaaU.Editor_buffer.cleanup_temporary temporary;
    fail "oversized temporary was created");
  match AaaU.Editor_buffer.create_temporary ~content:"temporary data" with
  | Error message -> fail "create_temporary failed: %s" message
  | Ok temporary ->
    (match AaaU.Editor_buffer.read_temporary temporary with
    | Ok "temporary data" -> ()
    | _ -> fail "temporary content mismatch");
    AaaU.Editor_buffer.cleanup_temporary temporary;
    AaaU.Editor_buffer.cleanup_temporary temporary;
    (match AaaU.Editor_buffer.read_temporary temporary with
    | Error _ -> ()
    | Ok _ -> fail "cleaned temporary could still be read")

let () =
  test_invalid_open ();
  with_temp test_owner_check;
  with_temp test_apply_response;
  test_temporary ();
  print_endline "editor buffer extended tests passed"
