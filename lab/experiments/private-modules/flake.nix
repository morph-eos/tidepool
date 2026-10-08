# The shape of a private repository that adds a module of its own to the public host (private-repo-template/README.md), with the LAB host standing in for the real one.
{
  inputs.tidepool.url = "path:/home/lab/pub/nixos";
  outputs = { self, tidepool, ... }: {
    nixosConfigurations.lab-extra = tidepool.lib.mkHost ({ ... }: {
      imports = [ "${tidepool}/hosts/lab" ./modules/hello.nix ];
      extra.hello.enable = true;
    });
  };
}
