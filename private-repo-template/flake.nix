# The PRIVATE repository: the values and the encrypted secrets of one machine, and a flake that imports the public one (ADR 0018). Copy this directory to a new private repository.
# `flake.lock` pins the revision of the public repository that the server deploys; the workflow .github/workflows/bump-public.yml opens a pull request that moves it.
{
  inputs.tidepool.url = "github:OWNER/tidepool?dir=nixos";   # the public repository; replace OWNER
  outputs = { self, tidepool, ... }: {
    nixosConfigurations.tidepool = tidepool.lib.mkHost ./host.nix;
  };
}
