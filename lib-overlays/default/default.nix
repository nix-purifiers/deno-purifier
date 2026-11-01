# SPDX-License-Identifier: MIT
#
# The `deno-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildDenoProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    deno-purifier = prev.deno-purifier or { };
  };

}
