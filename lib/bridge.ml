(** Server implementation *)

open Lwt.Syntax

let human_socket_mode = 0o660
let editor_socket_mode = 0o620
let human_peer_allowed ~agent_uid user = user.Auth.uid <> agent_uid
let groups_are_isolated ~agent_gid ~human_gid ~agent_username ~human_members =
  agent_gid <> human_gid && not (Array.exists (( = ) agent_username) human_members)

let set_group_if_needed path gid =
  if (Unix.stat path).Unix.st_gid <> gid then
    Unix.chown path (-1) gid

type t = {
  socket_path : string;
  editor_socket_path : string;
  shared_group : string;
  agent_user : string;
  default_program : string;
  default_args : string list;

  mutable server_socket : Lwt_unix.file_descr option;
  mutable editor_server_socket : Lwt_unix.file_descr option;
  audit : Audit.t;
  sessions : (string, Session.t) Hashtbl.t;
  sessions_lock : Lwt_mutex.t;
  mutable running : bool;
}

let create ~socket_path ?editor_socket_path ~shared_group ~agent_user ~log_dir ?(default_program="/bin/bash") ?(default_args=["-l"]) () =
  let editor_socket_path = Option.value editor_socket_path ~default:(socket_path ^ ".editor") in
  if socket_path = editor_socket_path then invalid_arg "Human and editor sockets must be distinct";
  let audit = Audit.create ~log_dir in
  {
    socket_path;
    editor_socket_path;
    shared_group;
    agent_user;
    default_program;
    default_args;
    server_socket = None;
    editor_server_socket = None;
    audit;
    sessions = Hashtbl.create 100;
    sessions_lock = Lwt_mutex.create ();
    running = false;
  }

let setup_socket t =
  let human_group = Unix.getgrnam t.shared_group in
  let agent_account = Unix.getpwnam t.agent_user in
  if agent_account.Unix.pw_uid = 0 then invalid_arg "Configured agent must not be root";
  if not (groups_are_isolated ~agent_gid:agent_account.Unix.pw_gid
            ~human_gid:human_group.Unix.gr_gid ~agent_username:t.agent_user
            ~human_members:human_group.Unix.gr_mem) then
    invalid_arg "Configured agent must not belong to the human control group";
  (* Clean up old socket *)
  (try Unix.unlink t.socket_path with _ -> ());

  (* Create directory *)
  let dir = Filename.dirname t.socket_path in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error _ -> ());

  (* Create socket *)
  let socket = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let* () = Lwt_unix.bind socket (Unix.ADDR_UNIX t.socket_path) in
  Lwt_unix.listen socket 5;
  let* () = Lwt.return_unit in

  (* Set permissions *)
  let gid = human_group.Unix.gr_gid in
  (* The service can run as the agent account.  Keeping the current owner
     makes that mode work; only the control group needs to be assigned. *)
  (* The systemd runtime directory is setgid, so the socket normally already
     has the human-control group. Avoid requiring that group as a
     supplementary privilege merely to repeat the inherited ownership. *)
  set_group_if_needed t.socket_path gid;
  Unix.chmod t.socket_path human_socket_mode;

  t.server_socket <- Some socket;

  Logs_lwt.info (fun m -> m "Server listening on %s" t.socket_path)

let setup_editor_socket t =
  (try Unix.unlink t.editor_socket_path with _ -> ());
  let dir = Filename.dirname t.editor_socket_path in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error _ -> ());
  let socket = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let* () = Lwt_unix.bind socket (Unix.ADDR_UNIX t.editor_socket_path) in
  Lwt_unix.listen socket 5;
  let account = Unix.getpwnam t.agent_user in
  set_group_if_needed t.editor_socket_path account.Unix.pw_gid;
  Unix.chmod t.editor_socket_path editor_socket_mode;
  t.editor_server_socket <- Some socket;
  Logs_lwt.info (fun m -> m "Agent editor requests listening on %s" t.editor_socket_path)

let authenticate_client t client_fd =
  let result = Auth.authenticate_socket (Lwt_unix.unix_file_descr client_fd) ~shared_group:t.shared_group in
  let agent_uid = (Unix.getpwnam t.agent_user).Unix.pw_uid in
  Lwt.return (match result with
    | Ok user when not (human_peer_allowed ~agent_uid user) -> Error "Agent account is denied on the human control socket"
    | other -> other)

let parse_new_json payload =
  match Yojson.Safe.from_string payload with
  | `Assoc fields ->
    let find_string key =
      match List.assoc_opt key fields with
      | Some (`String value) -> Ok value
      | _ -> Error (Printf.sprintf "Missing or invalid JSON field: %s" key)
    in
    let find_int key =
      match List.assoc_opt key fields with
      | Some (`Int value) -> Ok value
      | _ -> Error (Printf.sprintf "Missing or invalid JSON field: %s" key)
    in
    let find_args () =
      match List.assoc_opt "args" fields with
      | Some (`List values) ->
        let rec collect acc = function
          | [] -> Ok (List.rev acc)
          | (`String value) :: rest -> collect (value :: acc) rest
          | _ -> Error "Missing or invalid JSON field: args"
        in
        collect [] values
      | _ -> Error "Missing or invalid JSON field: args"
    in
    begin
      match find_string "program", find_args (), find_int "rows", find_int "cols" with
      | Ok program, Ok args, Ok rows, Ok cols
        when rows > 0 && rows <= 1000 && cols > 0 && cols <= 1000 ->
        Ok (program, args, rows, cols)
      | Ok _, Ok _, Ok _, Ok _ ->
        Error "Terminal dimensions must be between 1 and 1000"
      | Error e, _, _, _
      | _, Error e, _, _
      | _, _, Error e, _
      | _, _, _, Error e -> Error e
    end
  | _ -> Error "NEW_JSON payload must be a JSON object"

let handle_handshake t client_fd user_info =
  let* line_result = Client_io.read_line_with_remainder client_fd in
  match line_result with
  | Client_io.End_of_file ->
    Lwt.return_error "Connection closed"
  | Client_io.Timeout_line ->
    Lwt.return_error "Connection timed out"
  | Client_io.Line (msg, remaining) ->
    if String.starts_with ~prefix:"EDITOR_PROVIDER:" msg then
      let session_id = String.sub msg 16 (String.length msg - 16) in
      if remaining <> "" then Lwt.return_error "Unexpected bytes after editor provider handshake"
      else
        let* session = Lwt_mutex.with_lock t.sessions_lock (fun () -> Lwt.return (Hashtbl.find_opt t.sessions session_id)) in
        begin match session with
        | None -> Lwt.return_error (Printf.sprintf "Session %s not found" session_id)
        | Some session ->
          let* registered = Session.register_editor_provider session ~socket:client_fd ~user_info in
          begin match registered with
          | Error _ as error -> Lwt.return error
          | Ok stopped ->
            let response = Printf.sprintf "EDITOR_PROVIDER:%s\n" session_id in
            let* () = Client_io.write_all client_fd response in
            Lwt.return_ok (`Dedicated stopped)
          end
        end
    else if String.starts_with ~prefix:"SESSION:" msg then
      let session_id = String.sub msg 8 (String.length msg - 8) in
      Lwt_mutex.with_lock t.sessions_lock (fun () ->
        match Hashtbl.find_opt t.sessions session_id with
        | None -> Lwt.return_error (Printf.sprintf "Session %s not found" session_id)
        | Some session ->
          let response = Printf.sprintf "SESSION:%s\n" session_id in
          let* _ = Lwt_unix.write_string client_fd response 0 (String.length response) in
          Lwt.return_ok (`Existing (session, remaining))
      )
    else if String.starts_with ~prefix:"NEW_JSON:" msg then
      let payload = String.sub msg 9 (String.length msg - 9) in
      begin match parse_new_json payload with
      | Error e -> Lwt.return_error e
      | Ok (program, args, rows, cols) ->
        let session_id = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string in
        let* result = Session.create ~session_id ~creator:user_info ~agent_user:t.agent_user ~editor_socket_path:t.editor_socket_path
          ~program ~args ~rows ~cols ~audit:t.audit in
        match result with
        | Error e -> Lwt.return_error e
        | Ok session ->
          let* () =
            Lwt_mutex.with_lock t.sessions_lock (fun () ->
              Hashtbl.add t.sessions session_id session;
              Lwt.return_unit
            )
          in
          let response = Printf.sprintf "SESSION:%s\n" session_id in
          let* _ = Lwt_unix.write_string client_fd response 0 (String.length response) in
          Lwt.return_ok (`New (session, remaining))
      end
    else if String.starts_with ~prefix:"NEW" msg then
      (* Parse "NEW:rows:cols" or "NEW:program:rows:cols" or "NEW:program:arg1:arg2:...:rows:cols" *)
      (* Last two fields are always rows and cols *)
      let parts = String.split_on_char ':' msg in
      let program, args, rows, cols =
        match parts with
        | ["NEW"; rows_str; cols_str] ->
          (* NEW:rows:cols - use default program *)
          let r = int_of_string_opt rows_str |> Option.value ~default:24 in
          let c = int_of_string_opt cols_str |> Option.value ~default:80 in
          (t.default_program, t.default_args, r, c)
        | "NEW" :: prog :: rest when prog <> "" ->
          (* NEW:program:...:rows:cols - parse program, args, and size *)
          (* Last two elements should be rows and cols *)
          let len = List.length rest in
          if len >= 2 then
            let rows_str = List.nth rest (len - 2) in
            let cols_str = List.nth rest (len - 1) in
            match int_of_string_opt rows_str, int_of_string_opt cols_str with
            | Some r, Some c ->
              (* Extract args - everything between program and rows/cols *)
              let args = if len > 2 then 
                let rec take n lst = match n, lst with
                  | 0, _ | _, [] -> []
                  | n, x::xs -> x :: take (n-1) xs
                in
                take (len - 2) rest 
              else [] in
              (prog, args, r, c)
            | _ ->
              (* Not valid numbers, treat all as args with default size *)
              (prog, rest, 24, 80)
          else
            (* Not enough parts for rows/cols *)
            (prog, rest, 24, 80)
        | _ -> 
          (t.default_program, t.default_args, 24, 80)
      in
      let session_id = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string in
      let* result = Session.create ~session_id ~creator:user_info ~agent_user:t.agent_user ~editor_socket_path:t.editor_socket_path
        ~program ~args ~rows ~cols ~audit:t.audit in
      match result with
      | Error e -> Lwt.return_error e
      | Ok session ->
        let* () =
          Lwt_mutex.with_lock t.sessions_lock (fun () ->
            Hashtbl.add t.sessions session_id session;
            Lwt.return_unit
          )
        in
        let response = Printf.sprintf "SESSION:%s\n" session_id in
        let* _ = Lwt_unix.write_string client_fd response 0 (String.length response) in
        Lwt.return_ok (`New (session, remaining))
    else
      Lwt.return_error "Invalid handshake. Use SESSION:id or NEW"

let handle_client t client_fd addr =
  let* () = Logs_lwt.info (fun m -> m "New connection from %s" addr) in

  (* Authentication *)
  let* auth_result = authenticate_client t client_fd in
  match auth_result with
  | Error e ->
    let* _ = Lwt_unix.write_string client_fd ("Auth failed: " ^ e ^ "\n") 0
        (String.length e + 12) in
    Lwt_unix.close client_fd

  | Ok user_info ->
    (* Handshake - wrap in exception handling *)
    let* () = Lwt.try_bind
      (fun () ->
        let* handshake_result = handle_handshake t client_fd user_info in
        match handshake_result with
        | Error e ->
          let* _ = Lwt_unix.write_string client_fd (e ^ "\n") 0 (String.length e + 1) in
          Lwt_unix.close client_fd
        | Ok (`Dedicated work) -> work
        | Ok (`Existing _ | `New _ as handshake_result') ->
          let session, initial_buffer =
            match handshake_result' with
            | `Existing (s, remaining) -> (s, remaining)
            | `New (s, remaining) -> (s, remaining)
            | _ -> failwith "impossible"
          in

          (* Add client *)
          let* client_result =
            Session.add_client session ~socket:client_fd ~addr ~user_info
          in
          match client_result with
          | Error e ->
            let* _ = Lwt_unix.write_string client_fd (e ^ "\n") 0 (String.length e + 1) in
            Lwt_unix.close client_fd

          | Ok client ->
            (* Main loop: forward client input with framing *)
            let recv_buffer = ref initial_buffer in
            let rec parse_messages () =
              if String.length !recv_buffer > Protocol.max_frame_size + 4 then
                Lwt.fail_with "Client frame exceeds maximum size"
              else
                match Protocol.try_parse_framed !recv_buffer with
                | None -> Lwt.return_unit
                | Some (msg, remaining) ->
                  recv_buffer := remaining;
                  let* () = Session.handle_client_input session ~client ~data:msg in
                  parse_messages ()
            in
            let rec loop () =
              if not t.running then
                Lwt.return_unit
              else
                let buf = Bytes.create 4096 in
                let* n =
                  Lwt.catch
                    (fun () -> Lwt_unix.read client_fd buf 0 4096)
                    (fun _ -> Lwt.return 0)
                in

                if n = 0 then (
                  (* Client disconnected *)
                  let* () = Session.remove_client session client in
                  Lwt.return_unit
                ) else (
                  let data = Bytes.sub_string buf 0 n in
                  recv_buffer := !recv_buffer ^ data;

                  let* () = parse_messages () in
                  loop ()
                )
            in

            let* () = parse_messages () in
            let* () = loop () in
            (* Socket may already be closed by session cleanup *)
            let* () = Lwt.catch (fun () -> Lwt_unix.close client_fd) (fun _ -> Lwt.return_unit) in
            Lwt.return_unit
      )
      (fun () -> Lwt.return_unit)
      (fun exn ->
        let error_msg = Printf.sprintf "Handshake error: %s" (Printexc.to_string exn) in
        let* () = Logs_lwt.err (fun m -> m "%s" error_msg) in
        let* _ = Lwt_unix.write_string client_fd (error_msg ^ "\n") 0 (String.length error_msg + 1) in
        Lwt_unix.close client_fd)
    in
    Lwt.return_unit

let rec accept_loop t =
  if not t.running then
    Lwt.return_unit
  else
    match t.server_socket with
    | None -> Lwt.return_unit
    | Some socket ->
      let* client_fd, client_addr = Lwt_unix.accept socket in
      let addr =
        match client_addr with
        | Unix.ADDR_UNIX s -> s
        | _ -> "unknown"
      in

      (* One independent coroutine per client *)
      Lwt.async (fun () -> handle_client t client_fd addr);

      accept_loop t

let handle_editor_client t client_fd =
  let close () = Lwt.catch (fun () -> Lwt_unix.close client_fd) (fun _ -> Lwt.return_unit) in
  let fail message =
    let* () = Lwt.catch (fun () -> Client_io.write_all client_fd (message ^ "\n")) (fun _ -> Lwt.return_unit) in
    close ()
  in
  match Auth.authenticate_agent_socket (Lwt_unix.unix_file_descr client_fd) ~agent_user:t.agent_user with
  | Error message -> fail ("Auth failed: " ^ message)
  | Ok (user_info, peer_session_id) ->
    Lwt.catch
      (fun () ->
        let* line = Client_io.read_line_with_remainder ~timeout:5.0 client_fd in
        match line with
        | Client_io.Line (message, "") when String.starts_with ~prefix:"EDITOR_REQUEST:" message ->
          let session_id = String.sub message 15 (String.length message - 15) in
          let* session = Lwt_mutex.with_lock t.sessions_lock (fun () -> Lwt.return (Hashtbl.find_opt t.sessions session_id)) in
          begin match session with
          | None -> fail (Printf.sprintf "Session %s not found" session_id)
          | Some session when not (Session.editor_request_authorized session user_info ~peer_session_id) ->
            fail "Agent process does not belong to this session"
          | Some session ->
            let* () = Client_io.write_all client_fd ("EDITOR_REQUEST:" ^ session_id ^ "\n") in
            let* payload = Editor_protocol.read_frame ~timeout:5.0 client_fd in
            let* response = match payload with
              | Error message -> Lwt.return { Editor_protocol.request_id = "invalid"; status = 64; error = Some message; content = None }
              | Ok payload ->
                begin match Editor_protocol.request_of_string payload with
                | Error message -> Lwt.return { Editor_protocol.request_id = "invalid"; status = 64; error = Some message; content = None }
                | Ok request ->
                  Session.forward_editor_request session ~user_info ~peer_session_id
                    request.Editor_protocol.content
                end
            in
            let* _ = Editor_protocol.write_frame client_fd (Editor_protocol.response_to_string response) in
            close ()
          end
        | Client_io.Timeout_line -> fail "Connection timed out"
        | Client_io.End_of_file -> close ()
        | Client_io.Line _ -> fail "Editor socket accepts only EDITOR_REQUEST"
      )
      (fun exn -> fail ("Editor request error: " ^ Printexc.to_string exn))

let rec accept_editor_loop t =
  if not t.running then Lwt.return_unit
  else match t.editor_server_socket with
    | None -> Lwt.return_unit
    | Some socket ->
      let* client_fd, _ = Lwt_unix.accept socket in
      Lwt.async (fun () -> handle_editor_client t client_fd);
      accept_editor_loop t

let cleanup_sessions t =
  let rec loop () =
    let* () = Lwt_unix.sleep 60.0 in
    if not t.running then
      Lwt.return_unit
    else
      let* () =
        Lwt_mutex.with_lock t.sessions_lock (fun () ->
          let dead = ref [] in
          Hashtbl.iter (fun id session ->
            if not (Session.is_alive session) &&
               List.length (Session.get_clients session) = 0 then
              dead := (id, session) :: !dead
          ) t.sessions;

          List.iter (fun (id, session) ->
            Hashtbl.remove t.sessions id;
            Lwt.async (fun () -> Session.shutdown session)
          ) !dead;

          Lwt.return_unit
        )
      in
      loop ()
  in
  loop ()

let start t =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let* () = setup_socket t in
  let* () = setup_editor_socket t in
  t.running <- true;

  (* Start cleanup coroutine *)
  Lwt.async (fun () -> cleanup_sessions t);
  Lwt.async (fun () -> accept_editor_loop t);

  (* Main accept loop *)
  accept_loop t

let stop t =
  t.running <- false;

  (* Close socket *)
  (match t.server_socket with
   | Some s -> Lwt.async (fun () -> Lwt_unix.close s)
   | None -> ());
  (match t.editor_server_socket with
   | Some s -> Lwt.async (fun () -> Lwt_unix.close s)
   | None -> ());

  (* Close all sessions *)
  let* () =
    Lwt_mutex.with_lock t.sessions_lock (fun () ->
      Hashtbl.fold (fun _ session acc ->
        let* () = Session.shutdown session in
        acc
      ) t.sessions Lwt.return_unit
    )
  in

  (* Flush audit logs *)
  Audit.close t.audit
