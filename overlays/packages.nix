{ gpuSupport ? true }:
final: prev:
let
  # Voyager - Spotify's ANN library (not in nixpkgs)
  voyager = final.python312Packages.buildPythonPackage rec {
    pname = "voyager";
    version = "2.1.0";
    format = "wheel";

    src = final.fetchPypi {
      inherit pname version format;
      dist = "cp312";
      python = "cp312";
      abi = "cp312";
      platform = "manylinux_2_17_x86_64.manylinux2014_x86_64";
      hash = "sha256-lBW5ySO6xJPVxo1VrlXEKJFTwj+fR4Qik03mGsuvTAE=";
    };

    # Binary wheel, no build deps needed
    pythonImportsCheck = [ "voyager" ];

    meta = with final.lib; {
      description = "Spotify's library for approximate nearest-neighbor search";
      homepage = "https://github.com/spotify/voyager";
      license = licenses.asl20;
    };
  };

  # AudioMuse-AI Python environment with all dependencies
  audiomuse-ai-python = final.python312.withPackages (ps: with ps; [
    # Web framework
    flask
    flask-cors
    flasgger

    # Task queue
    redis
    rq

    # Database
    psycopg2

    # Audio processing
    librosa
    soundfile
    resampy
    pydub
    mutagen

    # ML/Scientific
    numpy
    scipy
    numba
    scikit-learn
    umap-learn
    transformers
    sentencepiece

    # ONNX
    onnx
    onnxruntime  # CUDA enabled via global cudaSupport = true

    # Utilities
    pyyaml
    requests
    rapidfuzz
    ftfy
    packaging
    protobuf
    httpx

    # LLM integrations
    google-genai
    mistralai

    # MCP (Model Context Protocol)
    mcp

    # Voyager (from our custom package)
    voyager
  ] ++ final.lib.optionals gpuSupport [
    # GPU-accelerated ML (RAPIDS cuML)
    cupy
    final.python312Packages.rmm
    final.python312Packages.pylibraft
    final.python312Packages.cuvs
    final.python312Packages.cuml
  ]);
in
{
  # AudioMuse-AI - Music analysis and playlist generation service
  audiomuse-ai = final.stdenvNoCC.mkDerivation {
    pname = "audiomuse-ai";
    version = "unstable-2025-02-10";

    src = final.fetchFromGitHub {
      owner = "NeptuneHub";
      repo = "AudioMuse-AI";
      rev = "b67d2e6284b0be9ef9087cede3931192301c3374";
      hash = "sha256-bJllS4R9VvrDNrEc03eMTk5Pn8MrX/k5W+h6RTKS8lI=";
    };

    nativeBuildInputs = [ final.makeWrapper ];

    buildInputs = [
      audiomuse-ai-python
      final.ffmpeg
    ];

    postPatch = ''
      substituteInPlace config.py \
        --replace-fail 'TEMP_DIR = "/app/temp_audio"' 'TEMP_DIR = os.environ.get("TEMP_DIR", "/tmp/audiomuse-temp")' \
        --replace-fail 'EMBEDDING_MODEL_PATH = "/app/model/msd-musicnn-1.onnx"' \
                       'EMBEDDING_MODEL_PATH = os.environ.get("EMBEDDING_MODEL_PATH", "/app/model/msd-musicnn-1.onnx")' \
        --replace-fail 'PREDICTION_MODEL_PATH = "/app/model/msd-msd-musicnn-1.onnx"' \
                       'PREDICTION_MODEL_PATH = os.environ.get("PREDICTION_MODEL_PATH", "/app/model/msd-msd-musicnn-1.onnx")'

      # Fix CLAP Conv fallback: use EXHAUSTIVE algo search + relaxed memory arena
      substituteInPlace tasks/clap_analyzer.py \
        --replace-fail "'cudnn_conv_algo_search': 'DEFAULT'" \
                       "'cudnn_conv_algo_search': 'EXHAUSTIVE'" \
        --replace-fail "'arena_extend_strategy': 'kSameAsRequested'" \
                       "'arena_extend_strategy': 'kNextPowerOfTwo'"
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib/audiomuse-ai
      cp -r . $out/lib/audiomuse-ai/

      mkdir -p $out/bin

      # Main Flask app
      makeWrapper ${audiomuse-ai-python}/bin/python $out/bin/audiomuse-ai \
        --add-flags "$out/lib/audiomuse-ai/app.py" \
        --prefix PATH : ${final.lib.makeBinPath [ final.ffmpeg ]} \
        --set PYTHONPATH "$out/lib/audiomuse-ai"

      # RQ Worker
      makeWrapper ${audiomuse-ai-python}/bin/python $out/bin/audiomuse-ai-worker \
        --add-flags "$out/lib/audiomuse-ai/rq_worker.py" \
        --prefix PATH : ${final.lib.makeBinPath [ final.ffmpeg ]} \
        --set PYTHONPATH "$out/lib/audiomuse-ai"

      # High-priority RQ Worker
      makeWrapper ${audiomuse-ai-python}/bin/python $out/bin/audiomuse-ai-worker-high \
        --add-flags "$out/lib/audiomuse-ai/rq_worker_high_priority.py" \
        --prefix PATH : ${final.lib.makeBinPath [ final.ffmpeg ]} \
        --set PYTHONPATH "$out/lib/audiomuse-ai"

      runHook postInstall
    '';

    meta = with final.lib; {
      description = "AI-powered music analysis and playlist generation";
      homepage = "https://github.com/NeptuneHub/AudioMuse-AI";
      license = licenses.mit;
      platforms = platforms.linux;
    };
  };

  # AudioMuse-AI ONNX models (~2GB total)
  audiomuse-ai-models = final.stdenvNoCC.mkDerivation {
    pname = "audiomuse-ai-models";
    version = "3.0.0";

    dontUnpack = true;

    # MusicNN models
    danceability = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v3.0.0-model/danceability-msd-musicnn-1.onnx";
      hash = "sha256-x7jlF0uC6gSVvKqcAmQJs/uOZSSfAsaj4HLC9VDP9No=";
    };
    mood_aggressive = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v3.0.0-model/mood_aggressive-msd-musicnn-1.onnx";
      hash = "sha256-HFV+PdXF8qUxlgeboYxu8cYjMpmZRS73imE6H0SXfoE=";
    };
    mood_happy = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v3.0.0-model/mood_happy-msd-musicnn-1.onnx";
      hash = "sha256-Q8S5L+3+YxUZWvpDNBw9jlyqE2vB7r9wr8EIEYryTeA=";
    };
    mood_party = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v3.0.0-model/mood_party-msd-musicnn-1.onnx";
      hash = "sha256-D5fwZtJEO7sqxs91QnBeVbLvVpZg4gxwEwNeyewvi1k=";
    };
    mood_relaxed = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v3.0.0-model/mood_relaxed-msd-musicnn-1.onnx";
      hash = "sha256-uQZYWQblqBPTwvrva1p3s2KWhCwPxcbrmnpr35oVh/Q=";
    };
    mood_sad = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v3.0.0-model/mood_sad-msd-musicnn-1.onnx";
      hash = "sha256-0Sjpf7coly19gnt4Gsso1xrD3LN7TUr9g6gS8WobJi0=";
    };
    msd_msd = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v3.0.0-model/msd-msd-musicnn-1.onnx";
      hash = "sha256-ug9Nv3teFAcEtfweq9ofdP45L6Zv2uhqSFN2waA4Beg=";
    };
    msd = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v3.0.0-model/msd-musicnn-1.onnx";
      hash = "sha256-6TR+BeNOID7gloTNLMewd+hAQnZvzZCKRqvHO8YqjZc=";
    };

    # CLAP models
    clap_audio = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v3.0.0-model/clap_audio_model.onnx";
      hash = "sha256-NBjHoJd4fIYzxlkQ/jVXcHHnMIS9LO6t7BnI+mC7KXY=";
    };
    clap_text = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v3.0.0-model/clap_text_model.onnx";
      hash = "sha256-IA1I85Bf8fJyr1AG3ZhR+UBxp93k6v2cB7wJxaxlpxQ=";
    };

    # HuggingFace models (BERT, RoBERTa, etc.)
    huggingface_models = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v3.0.0-model/huggingface_models.tar.gz";
      hash = "sha256-AqeNbkI0BMcnEWj3QPF+Q9vBCUf3Rt/EIFZwinRsyz0=";
    };

    nativeBuildInputs = [ final.gnutar final.gzip ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/models

      # MusicNN models
      cp $danceability $out/models/danceability-msd-musicnn-1.onnx
      cp $mood_aggressive $out/models/mood_aggressive-msd-musicnn-1.onnx
      cp $mood_happy $out/models/mood_happy-msd-musicnn-1.onnx
      cp $mood_party $out/models/mood_party-msd-musicnn-1.onnx
      cp $mood_relaxed $out/models/mood_relaxed-msd-musicnn-1.onnx
      cp $mood_sad $out/models/mood_sad-msd-musicnn-1.onnx
      cp $msd_msd $out/models/msd-msd-musicnn-1.onnx
      cp $msd $out/models/msd-musicnn-1.onnx

      # CLAP models
      cp $clap_audio $out/models/clap_audio_model.onnx
      cp $clap_text $out/models/clap_text_model.onnx

      # HuggingFace models (extract tarball)
      mkdir -p $out/cache/huggingface
      tar -xzf $huggingface_models -C $out/cache/huggingface

      runHook postInstall
    '';

    meta = with final.lib; {
      description = "ONNX models for AudioMuse-AI";
      homepage = "https://github.com/NeptuneHub/AudioMuse-AI";
      license = licenses.mit;
      platforms = platforms.all;
    };
  };

  # Navidrome plugins
  navidromePlugins = {
    # AudioMuse-AI plugin for Navidrome
    audiomuse-ai = final.buildGoModule {
      pname = "audiomuse-ai-nv-plugin";
      version = "unstable-2025-02-10";

      src = final.fetchFromGitHub {
        owner = "NeptuneHub";
        repo = "AudioMuse-AI-NV-plugin";
        rev = "c279bc118f1283f587247a36b9a9d654e6f52860";
        hash = "sha256-SWWafntBqdIZKvtXoa8efT2ChQeFU+8ms0YvmGu5t80=";
      };

      nativeBuildInputs = [ final.zip ];

      vendorHash = "sha256-pGusT8DChHLx1GZlBy4r/Ii6oILNwevc2EL4WkqhQIM=";

      env.CGO_ENABLED = "0";

      buildPhase = ''
        runHook preBuild
        GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o plugin.wasm .
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out/share/navidrome-plugins
        zip -j $out/share/navidrome-plugins/audiomuse-ai.ndp plugin.wasm manifest.json
        runHook postInstall
      '';

      meta = with final.lib; {
        description = "AudioMuse-AI plugin for Navidrome - AI-powered similar tracks";
        homepage = "https://github.com/NeptuneHub/AudioMuse-AI-NV-plugin";
        license = licenses.mit;
      };
    };

    discord-rich-presence = final.buildGoModule {
      pname = "discord-rich-presence";
      version = "0.3.0";

      src = final.fetchFromGitHub {
        owner = "navidrome";
        repo = "discord-rich-presence-plugin";
        rev = "v0.3.0";
        hash = "sha256-gmRi4nb7KC3GC6ZcmaE/BPa9FgChCZ21K+VzLAeeZzI=";
      };

      nativeBuildInputs = [ final.zip ];

      vendorHash = "sha256-tJ6syjhiB8FFwYyFBX+iKsjFzqf6mUZQgTN7M2Saum8=";

      env.CGO_ENABLED = "0";

      buildPhase = ''
        runHook preBuild
        GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o plugin.wasm .
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out/share/navidrome-plugins
        # Create .ndp package (zip file with manifest.json and plugin.wasm)
        zip -j $out/share/navidrome-plugins/discord-rich-presence.ndp plugin.wasm manifest.json
        runHook postInstall
      '';

      meta = with final.lib; {
        description = "Discord Rich Presence plugin for Navidrome";
        homepage = "https://github.com/navidrome/discord-rich-presence-plugin";
        license = licenses.gpl3Only;
      };
    };
  };

  # Valkey (Redis fork) has flaky cluster/replication tests — skip them
  valkey = prev.valkey.overrideAttrs (old: { doCheck = false; });

  # Navidrome 0.60.2 with plugin support
  # Use: pkgs.navidrome.override { plugins = with pkgs.navidromePlugins; [ discord-rich-presence ]; }
  navidrome = final.lib.makeOverridable (
    { plugins ? [ ] }:
    prev.navidrome.overrideAttrs (oldAttrs: rec {
      version = "0.60.2";
      src = final.fetchFromGitHub {
        owner = "navidrome";
        repo = "navidrome";
        rev = "v${version}";
        hash = "sha256-2PzQEmxjaCRDobv0XgUk39Kb+t6+XQuB51rjDAlzEto=";
      };
      vendorHash = "sha256-AZMwgGwgjQg/MoA3xo6QH4579UsFXoLD6NDC2mT9Dv0=";
      npmDeps = final.fetchNpmDeps {
        inherit src;
        sourceRoot = "${src.name}/ui";
        hash = "sha256-EA2WM7xaqP7rS0pjx+yXwpjdauaduvDefmFH73eByxI=";
      };

      postInstall = ''
        mkdir -p $out/share/plugins/
        ${final.lib.concatMapStringsSep "\n" (plugin: ''
          cp ${plugin}/share/navidrome-plugins/*.ndp $out/share/plugins/
        '') plugins}
      '';

      passthru = oldAttrs.passthru // {
        inherit plugins;
      };
    })
  ) { };
}
