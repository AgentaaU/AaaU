(** Agent-side helper for one editor buffer. *)

open Lwt.Syntax

let env name = match Sys.getenv_opt name with
  | Some value when value <> "" -> Ok value
  | _ -> Error (Printf.sprintf "%s is not set; editor forwarding is unavailable" name)

let exchange socket_path session_id content =
  let socket = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Lwt.finalize
    (fun () ->
      let* () = Lwt_unix.connect socket (Unix.ADDR_UNIX socket_path) in
      let* () = AaaU.Client_io.write_all socket ("EDITOR_REQUEST:" ^ session_id ^ "\n") in
      let* handshake = AaaU.Client_io.read_handshake_response socket in
      match handshake with
      | AaaU.Client_io.Timeout -> Lwt.return_error "Editor request handshake timed out"
      | AaaU.Client_io.Response (line, "") when line = "EDITOR_REQUEST:" ^ session_id ->
        let request = { AaaU.Editor_protocol.request_id = "client"; content } in
        let* sent = AaaU.Editor_protocol.write_frame socket (AaaU.Editor_protocol.request_to_string request) in
        begin match sent with
        | Error _ as error -> Lwt.return error
        | Ok () ->
          let* payload = AaaU.Editor_protocol.read_frame socket in
          begin match payload with Error _ as error -> Lwt.return error
          | Ok payload -> Lwt.return (AaaU.Editor_protocol.response_of_string payload)
          end
        end
      | AaaU.Client_io.Response (line, _) -> Lwt.return_error line)
    (fun () -> Lwt.catch (fun () -> Lwt_unix.close socket) (fun _ -> Lwt.return_unit))

let run () =
  match Array.to_list Sys.argv |> List.tl with
  | [path] ->
    begin match env "AAAU_EDITOR_SOCKET", env "AAAU_SESSION_ID",
                AaaU.Editor_buffer.open_source ~path ~owner_uid:(Unix.getuid ()) with
    | Error message, _, _ | _, Error message, _ | _, _, Error message -> Lwt.return (64, Some message)
    | Ok socket_path, Ok session_id, Ok source ->
      Lwt.finalize
        (fun () ->
          match AaaU.Editor_buffer.read_source source with
          | Error message -> Lwt.return (74, Some message)
          | Ok content ->
            let* result = Lwt.catch
              (fun () -> exchange socket_path session_id content)
              (fun exn -> Lwt.return_error (Printexc.to_string exn)) in
            begin match result with
            | Error message -> Lwt.return (69, Some message)
            | Ok response -> Lwt.return (AaaU.Editor_buffer.apply_response source response)
            end)
        (fun () -> AaaU.Editor_buffer.close_source source; Lwt.return_unit)
    end
  | _ -> Lwt.return (64, Some "Exactly one editor-buffer filename is required")

let () =
  let status, error = Lwt_main.run (run ()) in
  Option.iter (fun message -> Printf.eprintf "aaau-editor: %s\n%!" message) error;
  exit status
