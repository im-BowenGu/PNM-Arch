#!/usr/bin/env python3
"""build_asm.py — compose HDL/ modules into a complete assembly (pnm-assembly/v1).

Reads a JSON assembly schema, parses the referenced Verilog modules' ports
and parameters, validates every connection (existence, direction, width),
then emits a top-level wrapper + smoke testbench and runs iverilog/vvp.

Usage:
    python3 implementations/build_asm.py implementations/boards/node_board.json
    python3 implementations/build_asm.py <schema.json> --lint      # verilator only
    python3 implementations/build_asm.py <schema.json> --waves     # dump VCD
    python3 implementations/build_asm.py <schema.json> -o <outdir>

Exit 0 = schema valid, elaboration clean, simulation completed.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SCHEMA_VERSION = "pnm-assembly/v1"

REPO_ROOT = Path(__file__).resolve().parent.parent
HDL_DIR = REPO_ROOT / "HDL"


class Port:
    def __init__(self, direction, width_expr, name):
        self.direction = direction
        self.width_expr = width_expr
        self.name = name


class ModuleDef:
    def __init__(self, name, params, ports, source):
        self.name = name
        self.params = params
        self.ports = ports
        self.source = source


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def parse_params(header):
    params = []
    for m in re.finditer(
        r"\bparameter\s+(?:integer\s+)?\[?[^\]=]*?\]?\s*(\w+)\s*=\s*([^,\)]+)",
        header,
    ):
        params.append((m.group(1), m.group(2).strip()))
    return params


def parse_ports(body):
    ports = []
    for m in re.finditer(
        r"\b(input|output|inout)\s+(?:wire|reg|logic)?\s*(?:signed\s+)?"
        r"(\[[^\]]+\])?\s*(\w+)\s*(?=,|$|\)|/\*)",
        body,
        flags=re.M,
    ):
        direction, width, name = m.groups()
        ports.append(Port(direction, width.strip() if width else None, name))
    return ports


def scan_hdl():
    all_mods = {}
    mod_files = {}
    for f in sorted(HDL_DIR.glob("**/*.v")):
        if f.name.startswith("tb_"):
            continue
        for modname, mod in parse_module_file(f).items():
            all_mods[modname] = mod
            mod_files[modname] = f
    return all_mods, mod_files


def find_module_instances(text):
    """Yield module names instantiated in Verilog source.

    Paren-aware: parameter lists (#(...)) may themselves contain nested
    parens (e.g. .EXP(8), .MAN(7)), which a regex \"#\\([^)]*\\)\" cannot
    skip.  Scan tokens: identifier [ # ( balanced ) ] identifier ( .
    """
    ident = re.compile(r"[A-Za-z_]\w*")
    i, n = 0, len(text)
    while i < n:
        m = ident.search(text, i)
        if not m:
            break
        mod = m.group(0)
        j = m.end()
        k = j
        while k < n and text[k] in " \t\r\n":
            k += 1
        if k < n and text[k] == "#":
            l = k + 1
            while l < n and text[l] in " \t\r\n":
                l += 1
            if l < n and text[l] == "(":
                depth, l = 1, l + 1
                while l < n and depth:
                    if text[l] == "(":
                        depth += 1
                    elif text[l] == ")":
                        depth -= 1
                    l += 1
                k = l
                while k < n and text[k] in " \t\r\n":
                    k += 1
        # now expect: instance-name '(' (module may be instantiated without
        # parameters, so the name is required to disambiguate from keywords
        # like "if (" or "function (")
        if k >= n or text[k] not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_":
            i = m.end()
            continue
        im = ident.match(text, k)
        l = im.end() if im else k
        while l < n and text[l] in " \t\r\n":
            l += 1
        if l < n and text[l] == "(":
            yield mod
        i = m.end()


def resolve_deps(components, modules, mod_files):
    """Given a set of component module names, transitively add their
    internal instantiations until no new sources are found."""
    needed = set(components)
    files, seen = [], set()
    while needed:
        mod = needed.pop()
        if mod not in mod_files:
            continue
        src = mod_files[mod]
        if src in seen:
            continue
        seen.add(src)
        files.append(src)
        text = strip_comments(src.read_text())
        for sub_mod in find_module_instances(text):
            if sub_mod in mod_files and sub_mod not in seen:
                needed.add(sub_mod)
    return files


def parse_module_file(path):
    text = strip_comments(path.read_text())
    mods = {}
    for m in re.finditer(r"\bmodule\s+(\w+)\s*(#\s*\((.*?)\))?\s*\((.*?)\)\s*;",
                         text, flags=re.S):
        name = m.group(1)
        params = parse_params(m.group(3) or "")
        ports = parse_ports(m.group(4) or "")
        mods[name] = ModuleDef(name, params, ports, path)
    return mods


_IDENT = re.compile(r"[A-Za-z_]\w*")


def _eval_index(expr, inst_params):
    def repl(match):
        key = match.group(0)
        val = inst_params.get(key)
        return str(val) if isinstance(val, int) else key
    substituted = _IDENT.sub(repl, expr.strip())
    if re.fullmatch(r"[\d\s+\-*()]+", substituted):
        try:
            return int(eval(substituted, {"__builtins__": {}}, {}))
        except Exception:
            return None
    return None

def port_width_text(port, inst_params):
    """Return (bit_count_or_None, verilog_range_string) for a parsed port."""
    if port.width_expr is None:
        return 1, ""
    m = re.fullmatch(r"\[([^:\]]+)\s*:\s*([^\]]+)\]", port.width_expr.strip())
    if not m:
        return None, ""
    msb = _eval_index(m.group(1), inst_params)
    lsb = _eval_index(m.group(2), inst_params)
    if msb is None or lsb is None:
        return None, ""
    return abs(msb - lsb) + 1, f" [{max(msb, lsb)}:{min(msb, lsb)}]"


class AsmError(Exception):
    pass


def split_endpoint(ep):
    parts = ep.split(".", 1)
    if len(parts) != 2 or not parts[0] or not parts[1]:
        raise AsmError(f"malformed endpoint {ep!r} (want '<inst>.<port>' or 'ext.<name>')")
    return parts[0], parts[1]


def main():
    ap = argparse.ArgumentParser(description="Compose HDL modules into a simulable assembly")
    ap.add_argument("schema", type=Path)
    ap.add_argument("--lint", action="store_true")
    ap.add_argument("--no-sim", action="store_true", help="emit files only, skip compile/run")
    ap.add_argument("--waves", action="store_true")
    ap.add_argument("-o", "--outdir", type=Path, default=None)
    args = ap.parse_args()

    schema = json.loads(args.schema.read_text())
    if schema.get("schema") != SCHEMA_VERSION:
        sys.exit(f"error: unsupported schema {schema.get('schema')!r}; want {SCHEMA_VERSION!r}")
    name = schema["name"]
    outdir = args.outdir or (Path(__file__).resolve().parent / "build" / name)
    outdir.mkdir(parents=True, exist_ok=True)

    modules, mod_files = scan_hdl()
    ext = {p["name"]: p for p in schema.get("external", [])}
    comps = {c["instance"]: c for c in schema.get("components", [])}
    warnings = []

    for c in schema.get("components", []):
        if c["module"] not in modules:
            sys.exit(f"error: module {c['module']!r} not found under {HDL_DIR}")
        if not re.fullmatch(r"[A-Za-z_]\w*", c["instance"]):
            sys.exit(f"error: bad instance name {c['instance']!r}")

    def resolve(endpoint):
        head, port = split_endpoint(endpoint)
        if head == "ext":
            if port not in ext:
                raise AsmError(f"{endpoint}: no such external port")
            d = ext[port]["dir"]
            return ("output" if d == "input" else "input"), int(ext[port]["width"]), endpoint
        if head not in comps:
            raise AsmError(f"{endpoint}: no such instance {head!r}")
        comp = comps[head]
        mod = modules[comp["module"]]
        for p in mod.ports:
            if p.name == port:
                pw = next((p for p in mod.ports if p.name == port), None)
                if pw is None:
                    raise AsmError(f"{endpoint}: port {port!r} not on module {mod.name}")
                w_count, _w_text = port_width_text(pw, comp.get("params", {}))
                return pw.direction, w_count, endpoint
        raise AsmError(
            f"{endpoint}: port {port!r} not on module {mod.name} "
            f"(has: {', '.join(p.name for p in mod.ports)})"
        )

    driven_by = {}
    connections = []
    tieoffs = []

    for conn in schema.get("connections", []):
        drv_dir, drv_w, drv_ep = resolve(conn["from"])
        if drv_dir != "output":
            raise AsmError(f"{conn['from']}: driver must be an output (found {drv_dir})")
        loads = conn["to"] if isinstance(conn["to"], list) else [conn["to"]]
        for load_ep in loads:
            ld_dir, ld_w, _ = resolve(load_ep)
            if ld_dir != "input":
                raise AsmError(f"{load_ep}: load must be an input (found {ld_dir})")
            if drv_w is not None and ld_w is not None and drv_w != ld_w:
                raise AsmError(f"{conn['from']} ({drv_w}b) -> {load_ep} ({ld_w}b): width mismatch")
            if load_ep in driven_by:
                raise AsmError(f"{load_ep}: already driven by {driven_by[load_ep]}")
            driven_by[load_ep] = drv_ep
        connections.append((drv_ep, loads))

    for t in schema.get("tieoffs", []):
        ep = t["to"]
        ld_dir, _, _ = resolve(ep)
        if ld_dir != "input":
            raise AsmError(f"{ep}: tieoff target must be an input")
        if ep in driven_by:
            raise AsmError(f"{ep}: tied off but also driven by {driven_by[ep]}")
        driven_by[ep] = ("TIEOFF", t["value"])
        tieoffs.append(t)

    for head, comp in comps.items():
        mod = modules[comp["module"]]
        for p in mod.ports:
            ep = f"{head}.{p.name}"
            if p.direction == "input" and ep not in driven_by:
                warnings.append(f"dangling input: {ep}")

    for w in warnings:
        print("warning:", w)

    # ------------------------------------------------------------- net plan
    nets = {}          # net_name -> {"width": n|None, "driver": str|None}
    net_of_driver = {}

    def alloc_net(base, width):
        nm = "net_" + re.sub(r"\W+", "_", base)[:58]
        cand, i = nm, 1
        while cand in nets:
            i += 1
            cand = f"{nm}_{i}"
        nets[cand] = {"width": width, "driver": None}
        return cand

    const_assigns = []
    ext_out_assigns = []          # (ext_port_name, net)
    inst_conns = {h: [] for h in comps}

    for drv_ep, loads in connections:
        head, port = split_endpoint(drv_ep)
        if head == "ext":
            drv_net = port
            nets.setdefault(drv_net, {"width": int(ext[port]["width"]), "driver": "EXT_IN"})
        else:
            comp = comps[head]
            mod = modules[comp["module"]]
            width = next((port_width_text(p, comp.get("params", {}))[0]
                          for p in mod.ports if p.name == port), None)
            drv_net = alloc_net(drv_ep, width)
            inst_conns[head].append((port, drv_net))
        net_of_driver[drv_ep] = drv_net

        for load_ep in loads:
            lhead, lport = split_endpoint(load_ep)
            if lhead == "ext":
                ext_out_assigns.append((lport, drv_net))
            else:
                inst_conns[lhead].append((lport, drv_net))

    for t in tieoffs:
        head, port = split_endpoint(t["to"])
        width = next((port_width_text(p, comps[head].get("params", {}))[0]
                      for p in modules[comps[head]["module"]].ports if p.name == port), None)
        net = alloc_net(f"tie_{t['to']}", width)
        nets[net]["driver"] = t["value"]
        const_assigns.append((net, t["value"]))
        inst_conns[head].append((port, net))

    # ----------------------------------------------------------------- emit
    lines = [
        f"// AUTO-GENERATED by build_asm.py from {args.schema.name} -- do not edit",
        "`timescale 1ns/1ps",
        "",
        f"module {name}_top(",
    ]
    hdr = []
    for p in schema.get("external", []):
        w = "" if int(p["width"]) == 1 else f" [{int(p['width'])-1}:0]"
        hdr.append(f"    {'input ' if p['dir'] == 'input' else 'output'} wire{w} {p['name']}")
    lines.append(",\n".join(hdr))
    lines.append(");")

    for netname, info in sorted(nets.items()):
        if info["driver"] == "EXT_IN":
            continue
        w = info["width"]
        rng = "" if w == 1 else f" [{max(w,1)-1}:0]"
        lines.append(f"    wire{rng} {netname};")

    lines.append("")
    for netname, value in const_assigns:
        lines.append(f"    assign {netname} = {value};")

    for extport, net in ext_out_assigns:
        lines.append(f"    assign {extport} = {net};")

    lines.append("")
    for head in schema.get("components", []):
        h = head["instance"]
        mod = modules[head["module"]]
        plist = [f".{k}({v})" for k, v in head.get("params", {}).items()]
        clist = [f".{p}({n})" for p, n in inst_conns[h]]
        params_s = f" #({', '.join(plist)})" if plist else ""
        lines.append(f"    {mod.name}{params_s} {h} ({', '.join(clist)});")

    lines.append("")
    lines.append("endmodule")
    lines.append("")
    top_path = outdir / f"{name}_top.v"
    top_path.write_text("\n".join(lines))

    period_ns = schema.get("clock", {}).get("period_ns", 10)
    half_ns = period_ns / 2.0
    rst_cycles = schema.get("reset_cycles", 4)
    run_cycles = schema.get("run_cycles", 2000)
    tb_inputs = [p for p in schema.get("external", []) if p["dir"] == "input"]

    tb = ["// AUTO-GENERATED by build_asm.py -- do not edit",
          "`timescale 1ns/1ps", "",
          f"module tb_{name};"]
    for p in tb_inputs:
        w = "" if int(p["width"]) == 1 else f" [{int(p['width'])-1}:0]"
        init = " = 0" if p["name"].startswith("clk") else ""
        tb.append(f"    reg{w} {p['name']}{init};")
    for p in schema.get("external", []):
        if p["dir"] == "output":
            w = "" if int(p["width"]) == 1 else f" [{int(p['width'])-1}:0]"
            tb.append(f"    wire{w} {p['name']};")
    tb.append("")
    tb.append(f"    {name}_top dut (")
    portmap = [f"        .{p['name']}({p['name']})" for p in schema.get("external", [])]
    tb.append(",\n".join(portmap))
    tb.append("    );")
    tb.append("")
    clk_names = [p["name"] for p in tb_inputs if p["name"].startswith("clk")]
    clk0 = clk_names[0] if clk_names else None
    if clk0:
        tb.append(f"    always #{half_ns} {clk0} = ~{clk0};")
    if "rst_n" in [p["name"] for p in tb_inputs]:
        tb += ["    initial begin",
               f"        repeat ({rst_cycles}) @(posedge {clk0});",
               "        rst_n = 1;",
               "    end"]
    tb += ["    initial begin"]
    if args.waves:
        tb.append(f"        $dumpfile(\"{outdir}/{name}.vcd\"); $dumpvars;")
    tb += [f"        repeat ({run_cycles}) @(posedge {clk0});" if clk0 else f"        #{run_cycles * period_ns};",
           f"        $display(\"*** ASSEMBLY {name} SIMULATION PASSED ***\");",
           "        $finish;",
           "    end",
           "",
           "endmodule",
           ""]
    (outdir / f"tb_{name}.v").write_text("\n".join(tb))

    used_files = resolve_deps(
        {c["module"] for c in comps.values()}, modules, mod_files)
    (outdir / "filelist.f").write_text(
        "\n".join(str(f) for f in used_files) + "\n")

    if args.lint:
        cmd = (["verilator", "--lint-only", "-Wno-MULTITOP",
                "--top-module", f"{name}_top", "-I", str(HDL_DIR),
                str(top_path)] + [str(f) for f in used_files])
        print("+", " ".join(cmd))
        subprocess.run(cmd, check=True)
        print(f"LINT OK: {top_path}")
        return 0

    if args.no_sim:
        print(f"FILES EMITTED (no-sim): {outdir}")
        print(f"  top: {top_path}")
        print(f"  tb:  {outdir / f'tb_{name}.v'}")
        print(f"  flist: {outdir / 'filelist.f'}")
        return 0

    cmd = (["iverilog", "-g2005", "-I", str(HDL_DIR),
            "-o", str(outdir / f"{name}_top.out"),
            str(top_path), str(outdir / f"tb_{name}.v")]
           + [str(f) for f in used_files])
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)
    vvp = subprocess.run(["vvp", str(outdir / f"{name}_top.out")],
                         capture_output=True, text=True)
    sys.stdout.write(vvp.stdout)
    if vvp.returncode != 0:
        sys.stderr.write(vvp.stderr)
        sys.exit(vvp.returncode)
    if "PASSED" not in vvp.stdout:
        sys.exit("error: testbench did not report PASSED")
    print(f"OK: {outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
