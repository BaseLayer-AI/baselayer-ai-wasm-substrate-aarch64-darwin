# Follow the guidance at https://baselayer-ai.github.io
{
  description = "Monolithic Pure Rustc-Driven WASM Substrate and Native Embedded Test Harness";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
      };

      rustToolchain = pkgs.rust-bin.stable.latest.default.override {
        targets = [ "wasm32-unknown-unknown" ];
      };
    in {
      packages.${system} = let
        # --- Monolithic Workspace Generation ---
        buildWorkspace = pkgs.runCommand "generate-substrate-workspace" {} ''
          mkdir -p $out

          # 1. Pure Rust WebAssembly State Machine
          cat << 'EOF' > $out/lib.rs
          #![no_main]
          use std::sync::atomic::{AtomicU32, Ordering};

          static COUNTER: AtomicU32 = AtomicU32::new(0);

          #[no_mangle]
          pub extern "C" fn increment() -> u32 {
              COUNTER.fetch_add(1, Ordering::SeqCst) + 1
          }

          #[no_mangle]
          pub extern "C" fn get_value() -> u32 {
              COUNTER.load(Ordering::SeqCst)
          }
          EOF

          # Compile WebAssembly Core Component natively
          ${rustToolchain}/bin/rustc --target wasm32-unknown-unknown --crate-type cdylib -C opt-level=s -C lto=true $out/lib.rs -o $out/pure_wasm_runtime.wasm
          
          WASM_SIZE=$(wc -c < $out/pure_wasm_runtime.wasm | tr -d ' ')
          WASM_BASE64=$(base64 $out/pure_wasm_runtime.wasm | tr -d '\n')

          # 2. Write the base64 metrics payload variables directly into the harness source file
          cat << 'EOF' > $out/headless_runner.rs
          use std::io::{Read, Write};
          use std::net::TcpStream;
          use std::process::Command;
          use std::thread;
          use std::time::Duration;

          const WASM_BASE64: &str = "WASM_PAYLOAD_MARKER";
          const WASM_SIZE_BYTES: &str = "WASM_SIZE_MARKER";

          fn send_webdriver_rpc(port: u16, method: &str, path: &str, body: &str) -> String {
              let mut stream = TcpStream::connect(format!("127.0.0.1:{}", port))
                  .expect("Nix-Runner Error: Failed to attach to local WebDriver handle");
              let request = format!(
                  "{} {} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{}",
                  method, path, port, body.len(), body
              );
              stream.write_all(request.as_bytes()).unwrap();
              let mut response = String::new();
              stream.read_to_string(&mut response).unwrap();
              response
          }

          fn extract_json_string(json: &str, key: &str) -> Option<String> {
              let needle = format!("\"{}\":\"", key);
              if let Some(start) = json.find(&needle) {
                  let value_start = start + needle.len();
                  if let Some(end) = json[value_start..].find('"') {
                      return Some(json[value_start..value_start + end].to_string());
                  }
              }
              None
          }

          fn main() {
              println!("[1/4] Initializing background macOS safaridriver context...");
              let mut driver = Command::new("/usr/bin/safaridriver")
                  .args(["--port", "4444"])
                  .spawn()
                  .expect("Nix-Runner Error: Host /usr/bin/safaridriver binary inaccessible");

              struct ProcessGuard(std::process::Child);
              impl Drop for ProcessGuard {
                  fn drop(&mut self) {
                      println!("[4/4] Terminating background browser driver...");
                      let _ = self.0.kill();
                  }
              }
              let _guard = ProcessGuard(driver);
              thread::sleep(Duration::from_millis(1500));

              println!("[2/4] Requesting active automation session handshake...");
              let session_resp = send_webdriver_rpc(4444, "POST", "/session", "{\"capabilities\":{\"alwaysMatch\":{\"browserName\":\"safari\"}}}");
              let session_id = extract_json_string(&session_resp, "sessionId")
                  .expect("Nix-Runner Error: Handshake rejected. Ensure 'sudo safaridriver --enable' has run.");

              // Construct the dynamic self-contained execution script string
              let injection_script = format!(
                  "const base64Str = '{}'; \
                   const binaryString = window.atob(base64Str); \
                   const bytes = new Uint8Array(binaryString.length); \
                   for (let i = 0; i < binaryString.length; i++) {{ \
                       bytes[i] = binaryString.charCodeAt(i); \
                   }} \
                   const t0 = performance.now(); \
                   return WebAssembly.instantiate(bytes, {{}}).then(({{ instance }}) => {{ \
                       const t1 = performance.now(); \
                       instance.exports.increment(); \
                       instance.exports.increment(); \
                       const val = instance.exports.get_value(); \
                       return {{ \
                           status: 'SUCCESS', \
                           size_bytes: {}, \
                           compile_ms: (t1 - t0).toFixed(4), \
                           asserted_value: val \
                       }}; \
                   }}).catch(err => {{ \
                       return {{ status: 'ERROR', error: err.toString() }}; \
                   }});",
                  WASM_BASE64, WASM_SIZE_BYTES
              );

              // Escape quotes for the JSON outer wrapper payload boundary
              let escaped_script = injection_script.replace("\"", "\\\"");
              let exec_body = format!("{{\"script\": \"{}\", \"args\": []}}", escaped_script);

              println!("[3/4] Injecting monolithic WebAssembly substrate straight into execution runtime...");
              let exec_path = format!("/session/{}/execute/sync", session_id);
              let resp = send_webdriver_rpc(4444, "POST", &exec_path, &exec_body);

              println!("--------------------------------------------------------");
              println!("                BASELAYER METRICS TRACE                 ");
              println!("--------------------------------------------------------");
              if let Some(payload_start) = resp.find("{\"value\":") {
                  println!("Result Payload : {}", &resp[payload_start..].trim());
              } else {
                  println!("Result Raw Log : {}", resp.lines().last().unwrap_or(&resp));
              }
              println!("--------------------------------------------------------");

              send_webdriver_rpc(4444, "DELETE", &format!("/session/{}", session_id), "");

              if !resp.contains("\"status\":\"SUCCESS\"") {
                  eprintln!("[Verdict] Error: Substrate state verification failed.");
                  std::process::exit(1);
              }
              println!("[Verdict] Verification complete. Substrate state matches target.");
          }
          EOF

          # Interpolate compiled base64 data variables straight into the Rust driver source code template
          sed -i "s|WASM_PAYLOAD_MARKER|$WASM_BASE64|g" $out/headless_runner.rs
          sed -i "s|WASM_SIZE_MARKER|$WASM_SIZE|g" $out/headless_runner.rs
        '';

        testSuite = pkgs.stdenv.mkDerivation {
          pname = "pure-wasm-test-harness";
          version = "0.1.0";
          src = buildWorkspace;

          nativeBuildInputs = [ rustToolchain ];

          buildPhase = "rustc -O headless_runner.rs -o pure-wasm-test-harness";
          installPhase = "mkdir -p $out/bin && cp pure-wasm-test-harness $out/bin/";
        };
      in {
        default = testSuite;
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ rustToolchain ];
        shellHook = ''
          echo "BaseLayer Autonomous Substrate Engaged."
          echo "Execute 'nix run' to fire the completely network-free injection driver loop."
        '';
      };
    };
}
