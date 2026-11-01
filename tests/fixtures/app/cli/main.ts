import { greet } from "@fixture/greeting";
import { join } from "@std/path";
import { red, stripAnsiCode } from "https://deno.land/std@0.224.0/fmt/colors.ts";
// An unversioned deno.land/std URL redirects to the last std release there,
// so the lock records the redirect as well as the module.
import { bold } from "https://deno.land/std/fmt/colors.ts";
// A data: URL is part of the source and downloads nothing.
import suffix from "data:application/javascript,export default ')';";

const n = Number(Deno.args[0] ?? "3");
console.log(stripAnsiCode(bold(red(`${greet(n)} (${join("a", "b")}${suffix}`))));
