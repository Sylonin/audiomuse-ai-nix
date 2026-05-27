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
  audiomuse-ai = final.stdenvNoCC.mkDerivation rec {
    pname = "audiomuse-ai";
    version = "2.1.0";

    src = final.fetchFromGitHub {
      owner = "NeptuneHub";
      repo = "AudioMuse-AI";
      rev = "v${version}";
      hash = "sha256-EOHjsolE2Ae9z7z5A1E6Cq/pfP8SX7nQ6aKcHlel8F0=";
    };

    nativeBuildInputs = [ final.makeWrapper ];

    buildInputs = [
      audiomuse-ai-python
      final.ffmpeg
    ];

    postPatch = ''
      # TEMP_DIR is still hardcoded upstream — make it env-driven so the systemd
      # service can point at $DATA_DIR/temp_audio instead of /app/temp_audio
      substituteInPlace config.py \
        --replace-fail 'TEMP_DIR = "/app/temp_audio"  # Always use /app/temp_audio' \
                       'TEMP_DIR = os.environ.get("TEMP_DIR", "/tmp/audiomuse-temp")'

      # CLAP Conv fallback: EXHAUSTIVE algo search + relaxed memory arena
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

  # AudioMuse-AI ONNX models (v4.0.0-model release)
  # Note: danceability/mood_* models were dropped upstream in v4.0.0; the
  # musicnn embedding/prediction models were renamed.
  audiomuse-ai-models = final.stdenvNoCC.mkDerivation {
    pname = "audiomuse-ai-models";
    version = "4.0.0";

    dontUnpack = true;

    # MusicNN (renamed in v4.0.0-model)
    musicnn_embedding = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/musicnn_embedding.onnx";
      hash = "sha256-pIrYh5UKVXrvu03N31itSAIhP/X8b7Ue2jUHzXl7ubA=";
    };
    musicnn_prediction = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/musicnn_prediction.onnx";
      hash = "sha256-DU543UPGEK7IjAmeQfSolpeX2lrCYS6myiH6qeGkKPM=";
    };

    # CLAP teacher models (the v2.1.0 default points at model_epoch_36.onnx which
    # isn't released; we ship the teacher and pin CLAP_AUDIO_MODEL_PATH in the module)
    clap_audio = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/clap_audio_model.onnx";
      hash = "sha256-NBjHoJd4fIYzxlkQ/jVXcHHnMIS9LO6t7BnI+mC7KXY=";
    };
    clap_text = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/clap_text_model.onnx";
      hash = "sha256-IA1I85Bf8fJyr1AG3ZhR+UBxp93k6v2cB7wJxaxlpxQ=";
    };

    # HuggingFace models (BERT, RoBERTa, etc.)
    huggingface_models = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/huggingface_models.tar.gz";
      hash = "sha256-AqeNbkI0BMcnEWj3QPF+Q9vBCUf3Rt/EIFZwinRsyz0=";
    };

    # Lyrics analysis model bundle (new in v4.0.0-model)
    lyrics_model = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/lyrics_model.tar.gz";
      hash = "sha256-mnS/mSV6xrQD+10FVEoO4yZ1i+2ybaSYTxIiIZMZUpY=";
    };

    nativeBuildInputs = [ final.gnutar final.gzip ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/models

      # MusicNN
      cp $musicnn_embedding $out/models/musicnn_embedding.onnx
      cp $musicnn_prediction $out/models/musicnn_prediction.onnx

      # CLAP
      cp $clap_audio $out/models/clap_audio_model.onnx
      cp $clap_text $out/models/clap_text_model.onnx

      # HuggingFace cache
      mkdir -p $out/cache/huggingface
      tar -xzf $huggingface_models -C $out/cache/huggingface

      # Lyrics models — extract into the same dir AudioMuse-AI's
      # LYRICS_MODEL_DIR points at
      tar -xzf $lyrics_model -C $out/models

      runHook postInstall
    '';

    meta = with final.lib; {
      description = "ONNX models for AudioMuse-AI";
      homepage = "https://github.com/NeptuneHub/AudioMuse-AI";
      license = licenses.mit;
      platforms = platforms.all;
    };
  };

  # Navidrome plugins — extend the upstream navidromePlugins set with our
  # AudioMuse-AI plugin. discord-rich-presence is already in upstream
  # nixos-unstable (navidromePlugins.discord-rich-presence v1.0.0).
  navidromePlugins = prev.navidromePlugins.extend (self: super: {
    audiomuse-ai = final.buildNavidromePlugin {
      pname = "audiomuse-ai";
      version = "unstable-2026-05-13";

      src = final.fetchFromGitHub {
        owner = "NeptuneHub";
        repo = "AudioMuse-AI-NV-plugin";
        rev = "66154bbdd76dd2159b70ec2ac5bc09cc57e20baf";
        hash = "sha256-8MTCyIxLaPkXGsATq44PNx2yJzgaWpp5c4hg0J+j6Yo=";
      };

      vendorHash = "sha256-mXes+doBSa5kcfHp1cuzTz30wnyyPN7NLC0iOSL8FDo=";

      meta = with final.lib; {
        description = "AudioMuse-AI plugin for Navidrome - AI-powered similar tracks";
        homepage = "https://github.com/NeptuneHub/AudioMuse-AI-NV-plugin";
        license = licenses.mit;
      };
    };
  });

  # Valkey (Redis fork) has flaky cluster/replication tests — skip them
  valkey = prev.valkey.overrideAttrs (old: { doCheck = false; });
}
