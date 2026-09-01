
{
  # Present on the deployed system: lets a wheel user run nixos-rebuild
  # locally without unsigned-path errors.
  nix.settings.trusted-users = [ "root" "@wheel" ];
}
