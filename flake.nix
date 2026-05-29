{
  description = "AudioMuse-AI — AI-powered music analysis and playlist generation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    lib = nixpkgs.lib;

    # Individual overlay files
    pythonOverlay = import ./overlays/python.nix;
    rapidsOverlay = import ./overlays/rapids.nix;
    packagesOverlayGpu = import ./overlays/packages.nix { gpuSupport = true; };
    packagesOverlayCpu = import ./overlays/packages.nix { gpuSupport = false; };

    # Composed overlays for consumers
    nvidiaOverlay = lib.composeManyExtensions [
      pythonOverlay
      rapidsOverlay
      packagesOverlayGpu
    ];

    cpuOverlay = lib.composeManyExtensions [
      pythonOverlay
      packagesOverlayCpu
    ];

    # Instantiate nixpkgs for GPU variant
    pkgsNvidia = import nixpkgs {
      inherit system;
      config = {
        allowUnfree = true;
        cudaSupport = true;
      };
      overlays = [ nvidiaOverlay ];
    };

    # Instantiate nixpkgs for CPU variant
    pkgsCpu = import nixpkgs {
      inherit system;
      config = {
        allowUnfree = true;
      };
      overlays = [ cpuOverlay ];
    };
  in
  {
    # Overlays for consumers to apply to their own nixpkgs
    overlays = {
      nvidia = nvidiaOverlay;
      cpu = cpuOverlay;
      default = nvidiaOverlay;
    };

    # Pre-built packages
    packages.${system} = {
      audiomuse-ai-nvidia = pkgsNvidia.audiomuse-ai;
      audiomuse-ai-cpu = pkgsCpu.audiomuse-ai;
      audiomuse-ai-models = pkgsCpu.audiomuse-ai-models;
      navidromePlugins-audiomuse-ai = pkgsCpu.navidromePlugins.audiomuse-ai;
      default = pkgsNvidia.audiomuse-ai;
    };

    # NixOS module
    nixosModules = {
      audiomuse-ai = import ./modules/audiomuse.nix;
      default = self.nixosModules.audiomuse-ai;
    };
  };
}
