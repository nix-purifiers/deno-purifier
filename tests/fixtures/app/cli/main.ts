import { greet } from "@fixture/greeting";
import { join } from "@std/path";
import { red, stripAnsiCode } from "https://deno.land/std@0.224.0/fmt/colors.ts";

const n = Number(Deno.args[0] ?? "3");
console.log(stripAnsiCode(red(`${greet(n)} (${join("a", "b")})`)));
