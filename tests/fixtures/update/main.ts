// SPDX-License-Identifier: MIT
//
// A project whose deno.lock pins an old version of @std/path that its
// version requirement allows, for the conformance-update check.
import { join } from "@std/path";

console.log(join("a", "b"));
