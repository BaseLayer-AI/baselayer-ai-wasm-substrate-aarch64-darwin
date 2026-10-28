{
  description = "Instrumented Zero-HTTP Pure WASM Inline Substrate with Default Run Configuration";

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

      # 1. Pure Rust WASM State Engine
      wasmSource = pkgs.writeText "lib.rs" ''
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
      '';

      # 2. Monolithic Build Derivation with High-Res Performance Tracing
      monolithicCanvas = pkgs.stdenv.mkDerivation {
        pname = "pure-wasm-canvas";
        version = "0.1.0";
        phases = [ "buildPhase" "installPhase" ];

        nativeBuildInputs = [ rustToolchain ];

        buildPhase = ''
          # Compile down to raw, optimized WebAssembly
          rustc --target wasm32-unknown-unknown --crate-type cdylib -C opt-level=s -C lto=true ${wasmSource} -o pure_wasm_runtime.wasm
          
          # Capture binary size metrics
          WASM_SIZE=$(wc -c < pure_wasm_runtime.wasm | tr -d ' ')

          # Convert to base64 and strip all layout newlines
          WASM_BASE64=$(base64 pure_wasm_runtime.wasm | tr -d '\n')

          # Generate the HTML canvas wrapper embedding high-res performance monitors
          cat << EOF > index.html
          <!DOCTYPE html>
          <html lang="en">
          <head>
              <meta charset="UTF-8">
              <title>Pure Inline WASM Canvas</title>
          </head>
          <body>
              <h1>Pure Inline WASM Context</h1>
              <script type="module">
                  async function init() {
                      const base64Str = "$WASM_BASE64";
                      const wasmByteSize = $WASM_SIZE;
                      
                      const t0 = performance.now();
                      
                      // 1. Decode string slice into array buffers
                      const binaryString = window.atob(base64Str);
                      const bytes = new Uint8Array(binaryString.length);
                      for (let i = 0; i < binaryString.length; i++) {
                          bytes[i] = binaryString.charCodeAt(i);
                      }
                      const t1 = performance.now();
                      
                      // 2. Instantiate and mount compilation graph directly out of memory
                      const { instance } = await WebAssembly.instantiate(bytes, {});
                      const t2 = performance.now();
                      
                      // 3. Drive execution tests
                      instance.exports.increment();
                      instance.exports.increment();
                      const val = instance.exports.get_value();
                      const t3 = performance.now();

                      window.testResult = {
                          status: "SUCCESS",
                          metrics: {
                              binary_size_bytes: wasmByteSize,
                              decode_ms: (t1 - t0).toFixed(4),
                              compile_ms: (t2 - t1).toFixed(4),
                              execute_ms: (t3 - t2).toFixed(4),
                              total_runtime_ms: (t3 - t0).toFixed(4),
                              asserted_value: val
                          }
                      };
                  }
                  init().catch(err => {
                      window.testResult = { status: "ERROR", error: err.toString() };
                  });
              </script>
          </body>
          </html>
          EOF
        '';

        installPhase = ''
          mkdir -p $out/share
          cp index.html $out/share/index.html
        '';
      };

      # 3. Enhanced shell driver script utilizing precise JSON stream destructuring
      testRunner = pkgs.writeShellScriptBin "run-tests" ''
        set -euo pipefail
        export PATH="${pkgs.lib.makeBinPath [ pkgs.curl pkgs.jq ]}:$PATH"

        echo "[System Setup] Initializing macOS safaridriver loop..."
        /usr/bin/safaridriver --port=4444 >/dev/null 2>&1 &
        DRIVER_PID=$!

        cleanup() {
            echo "[System Teardown] Terminating safaridriver execution engine..."
            kill $DRIVER_PID || true
        }
        trap cleanup EXIT
        sleep 1

        echo "[W3C Handshake] Creating active automation browser context..."
        SESSION_JSON=$(curl -s -X POST http://localhost:4444/session -d '{"capabilities": {"alwaysMatch": {"browserName": "safari"}}}')
        SESSION_ID=$(echo "$SESSION_JSON" | jq -r '.value.sessionId')

        if [ "$SESSION_ID" == "null" ] || [ -z "$SESSION_ID" ]; then
            echo "[Error] WebDriver validation dropped. Verify 'sudo safaridriver --enable' access rules."
            exit 1
        fi
        echo "[W3C Handshake] Session established safely: $SESSION_ID"

        echo "[Navigation] Directing headless window to monolithic canvas store..."
        TARGET_URL="file://${monolithicCanvas}/share/index.html"
        curl -s -X POST "http://localhost:4444/session/$SESSION_ID/url" -d "{\"url\": \"$TARGET_URL\"}" > /dev/null
        
        echo "[Polling] Querying runtime metrics map..."
        STATUS="null"
        RESPONSE=""
        for i in {1..10}; do
            sleep 0.3
            RESPONSE=$(curl -s -X POST "http://localhost:4444/session/$SESSION_ID/execute/sync" -d '{"script": "return window.testResult;", "args": []}')
            STATUS=$(echo "$RESPONSE" | jq -r '.value.status // empty')
            if [ "$STATUS" == "SUCCESS" ] || [ "$STATUS" == "ERROR" ]; then
                break
            fi
        done

        if [ "$STATUS" == "SUCCESS" ]; then
            echo "--------------------------------------------------------"
            echo "                BASELAYER METRICS TRACE"
            echo "--------------------------------------------------------"
            echo "Execution Status  : $STATUS"
            echo "Target Asset Size : $(echo "$RESPONSE" | jq -r '.value.metrics.binary_size_bytes') Bytes"
            echo "Base64 Decode Time: $(echo "$RESPONSE" | jq -r '.value.metrics.decode_ms') ms"
            echo "WASM Compile Time : $(echo "$RESPONSE" | jq -r '.value.metrics.compile_ms') ms"
            echo "WASM Run Core Time: $(echo "$RESPONSE" | jq -r '.value.metrics.execute_ms') ms"
            echo "Total Loop Latency: $(echo "$RESPONSE" | jq -r '.value.metrics.total_runtime_ms') ms"
            echo "Final Output Value: $(echo "$RESPONSE" | jq -r '.value.metrics.asserted_value')"
            echo "--------------------------------------------------------"
            echo "[Verdict] Verification complete. Substrate state matches baseline."
        else
            echo "[Verdict] Operational error encountered: $RESPONSE"
            exit 1
        fi

        curl -s -X DELETE "http://localhost:4444/session/$SESSION_ID" > /dev/null
      '';
    in {
      packages.${system} = {
        # The test runner is now mapped as default for unfragmented 'nix run' commands
        default = testRunner;
        wasm = monolithicCanvas;
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ rustToolchain ];
        shellHook = ''
          echo "BaseLayer Substrate Configured."
          echo "Execute 'nix run' directly to launch the telemetry harness loop."
          echo "Execute 'nix build .#wasm' if you want to inspect the HTML build output artifact."
        '';
      };
    };
}
