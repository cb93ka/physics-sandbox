#!/usr/bin/env python3
"""Проверка data/materials.json и data/reactions.json по docs/materials-format.md.

Запуск: python3 data/validate.py [путь к папке data]
Код выхода 0 — ошибок нет (предупреждения допустимы), 1 — есть ошибки.
"""
import json
import os
import re
import sys

DATA = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))

errors, warnings = [], []
def err(msg): errors.append(msg)
def warn(msg): warnings.append(msg)

STATES = {"empty", "solid", "powder", "liquid", "gas", "fire"}
MAT_KEYS = {
    "id", "name", "category", "state", "density", "conductivity", "heat_capacity",
    "thermal_expansion", "initial_temp", "colors", "glow", "viscosity", "lifetime", "decay_into",
    "melt", "freeze", "boil", "condense", "ignite", "explosive", "acid", "acid_resistance",
    "nuclear", "fixed_temp", "hidden", "desc",
    # v0.1.1
    "wind_coupling", "gas_alpha", "fan", "emit", "drain",
}
REQUIRED = {"id": str, "name": str, "category": str, "state": str,
            "density": (int, float), "conductivity": (int, float), "heat_capacity": (int, float),
            "colors": list}
NUC_PROB = ["fissile", "fast_fission", "absorb", "moderate", "reflect", "burnup_chance", "poison_chance"]
NUC_KEYS = set(NUC_PROB) | {"spontaneous", "decay_heat", "fission_energy", "neutrons_per_fission",
                            "burnup_into", "poison_into"}
# Переход: из каких состояний → в какое состояние
# melt → gas — сублимация (сухой лёд, UF6), condense → solid/powder — обратная десублимация.
TRANSITIONS = {
    "melt": ({"solid", "powder"}, {"liquid", "gas"}),
    "freeze": ({"liquid"}, {"solid", "powder"}),
    "boil": ({"liquid"}, {"gas"}),
    "condense": ({"gas"}, {"liquid", "solid", "powder"}),
}
INVERSE = {"melt": "freeze", "freeze": "melt", "boil": "condense", "condense": "boil"}
SUBLIM_INVERSE = {"melt": "condense", "condense": "melt"}
ID_RE = re.compile(r"^[a-z][a-z0-9]*(_[a-z0-9]+)*$")
COLOR_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def in01(v):
    return is_num(v) and 0.0 <= v <= 1.0


def pair(v, typ=(int, float)):
    return (isinstance(v, list) and len(v) == 2 and all(isinstance(x, typ) and not isinstance(x, bool)
                                                         for x in v) and v[0] <= v[1])


def load(name):
    path = os.path.join(DATA, name)
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        err(f"{name}: не читается: {e}")
        return None


def check_materials(doc):
    for key, typ in (("version", int), ("cell_size_m", (int, float)), ("ambient_temp", (int, float)),
                     ("thermal_time_scale", (int, float)), ("categories", list), ("materials", list)):
        if not isinstance(doc.get(key), typ) or isinstance(doc.get(key), bool):
            err(f"materials.json: поле верхнего уровня '{key}' отсутствует или не того типа")
    if errors:
        return {}, {}
    if doc["cell_size_m"] <= 0 or doc["thermal_time_scale"] <= 0:
        err("cell_size_m и thermal_time_scale должны быть > 0")
    ambient = doc["ambient_temp"]

    cats = set()
    for c in doc["categories"]:
        if not isinstance(c, dict) or not isinstance(c.get("id"), str) or not isinstance(c.get("name"), str):
            err(f"категория неверна: {c}")
            continue
        if c["id"] in cats:
            err(f"категория '{c['id']}' повторяется")
        cats.add(c["id"])

    mats = doc["materials"]
    if not mats:
        err("materials пуст")
        return {}, {}
    if len(mats) > 255:
        err(f"материалов {len(mats)} > 255")
    by_id = {}
    for i, mt in enumerate(mats):
        if not isinstance(mt, dict):
            err(f"materials[{i}] не объект")
            continue
        mid = mt.get("id", f"#{i}")
        if mid in by_id:
            err(f"{mid}: id повторяется")
        by_id[mid] = mt
    if mats[0].get("id") != "air":
        err("первым материалом (id 0) должен быть air")
    else:
        if mats[0].get("state") != "empty":
            err("air: state должен быть 'empty'")
        if mats[0].get("category") != "special":
            err("air: category должна быть 'special'")

    def ref(where, target, allow_null=False):
        if target is None and allow_null:
            return True
        if not isinstance(target, str) or target not in by_id:
            err(f"{where}: ссылка на несуществующий материал {target!r}")
            return False
        return True

    for mt in mats:
        if not isinstance(mt, dict):
            continue
        mid = mt.get("id", "?")
        for key in mt:
            if key not in MAT_KEYS:
                err(f"{mid}: неизвестное поле '{key}'")
        for key, typ in REQUIRED.items():
            v = mt.get(key)
            if v is None or not isinstance(v, typ) or isinstance(v, bool):
                err(f"{mid}: обязательное поле '{key}' отсутствует или не того типа")
        if not isinstance(mid, str) or not ID_RE.match(mid):
            err(f"{mid}: id не snake_case латиницей")
        st = mt.get("state")
        if st not in STATES:
            err(f"{mid}: неизвестный state {st!r}")
        if st == "empty" and mid != "air":
            err(f"{mid}: state 'empty' разрешён только у air")
        if mt.get("category") not in cats:
            err(f"{mid}: категория {mt.get('category')!r} не объявлена")
        for key in ("density", "conductivity", "heat_capacity"):
            if is_num(mt.get(key)) and mt[key] <= 0:
                err(f"{mid}: {key} должно быть > 0")
        cols = mt.get("colors")
        if isinstance(cols, list):
            if not 1 <= len(cols) <= 4:
                err(f"{mid}: colors — от 1 до 4 цветов, сейчас {len(cols)}")
            for c in cols:
                if not isinstance(c, str) or not COLOR_RE.match(c):
                    err(f"{mid}: цвет {c!r} не в формате #RRGGBB")
        if not isinstance(mt.get("desc", ""), str):
            err(f"{mid}: desc не строка")
        elif not mt.get("desc"):
            warn(f"{mid}: нет desc")
        for key in ("glow", "hidden"):
            if key in mt and not isinstance(mt[key], bool):
                err(f"{mid}: {key} должен быть bool")
        for key in ("thermal_expansion", "initial_temp", "fixed_temp"):
            if key in mt and not is_num(mt[key]):
                err(f"{mid}: {key} должно быть числом")
        if "viscosity" in mt:
            if not in01(mt["viscosity"]):
                err(f"{mid}: viscosity вне 0..1")
            if st != "liquid":
                warn(f"{mid}: viscosity задана не жидкости")
        if "acid_resistance" in mt and not in01(mt["acid_resistance"]):
            err(f"{mid}: acid_resistance вне 0..1")
        if "lifetime" in mt:
            if not pair(mt["lifetime"]) or mt["lifetime"][0] <= 0:
                err(f"{mid}: lifetime должен быть [min, max], 0 < min ≤ max")
            if st not in ("gas", "fire"):
                warn(f"{mid}: lifetime у материала в состоянии {st}")
        if "decay_into" in mt:
            ref(f"{mid}.decay_into", mt["decay_into"])
            if "lifetime" not in mt:
                warn(f"{mid}: decay_into без lifetime")
        if st == "fire" and "lifetime" not in mt:
            err(f"{mid}: у огня должен быть lifetime")
        if "fixed_temp" in mt and st != "solid":
            err(f"{mid}: fixed_temp допустим только у solid")

        # v0.1.1: воздух, вентиляторы, источники, стоки
        if "wind_coupling" in mt:
            if not in01(mt["wind_coupling"]):
                err(f"{mid}: wind_coupling вне 0..1")
            if st not in ("gas", "fire", "powder"):
                warn(f"{mid}: wind_coupling у {st} не используется")
        if "gas_alpha" in mt:
            if not in01(mt["gas_alpha"]):
                err(f"{mid}: gas_alpha вне 0..1")
            if st not in ("gas", "fire"):
                warn(f"{mid}: gas_alpha у {st} не используется")
        if "fan" in mt:
            f = mt["fan"]
            if not isinstance(f, dict) or set(f) != {"dir", "strength"}:
                err(f"{mid}.fan: нужны ровно поля dir, strength")
            else:
                d = f["dir"]
                if not (isinstance(d, list) and len(d) == 2 and all(is_num(x) for x in d)
                        and any(x != 0 for x in d)):
                    err(f"{mid}.fan.dir должен быть ненулевым вектором [x, y]")
                if not is_num(f["strength"]) or f["strength"] <= 0:
                    err(f"{mid}.fan.strength должно быть > 0")
        if "emit" in mt:
            e = mt["emit"]
            if not isinstance(e, dict) or set(e) != {"into", "rate", "temp"}:
                err(f"{mid}.emit: нужны ровно поля into, rate, temp")
            else:
                if ref(f"{mid}.emit.into", e["into"]):
                    if by_id[e["into"]].get("state") in ("solid", "empty"):
                        err(f"{mid}.emit.into: выпускать можно только не-solid и не air")
                    if e["into"] == mid:
                        err(f"{mid}.emit.into: источник выпускает сам себя")
                if not is_num(e["rate"]) or e["rate"] <= 0:
                    err(f"{mid}.emit.rate должно быть > 0")
                if e["temp"] is not None and not is_num(e["temp"]):
                    err(f"{mid}.emit.temp — число или null")
        if "drain" in mt:
            dr = mt["drain"]
            if not isinstance(dr, dict) or set(dr) != {"rate"} or not is_num(dr["rate"]) or dr["rate"] <= 0:
                err(f"{mid}.drain: нужно поле rate > 0")
        for key in ("fan", "emit", "drain"):
            if key in mt and st != "solid":
                err(f"{mid}: {key} допустим только у solid")
        if sum(k in mt for k in ("fan", "emit", "drain")) > 1:
            warn(f"{mid}: у материала сразу несколько из fan/emit/drain")

        # Фазовые переходы
        for tr, (src_states, dst_states) in TRANSITIONS.items():
            if tr not in mt:
                continue
            p = mt[tr]
            if not isinstance(p, dict) or set(p) != {"temp", "into", "latent"}:
                err(f"{mid}.{tr}: нужны ровно поля temp, into, latent")
                continue
            if not is_num(p["temp"]) or not is_num(p["latent"]) or p["latent"] < 0:
                err(f"{mid}.{tr}: temp и latent — числа, latent ≥ 0")
                continue
            if p["temp"] < -273.15:
                err(f"{mid}.{tr}: температура ниже абсолютного нуля")
            if st not in src_states:
                err(f"{mid}.{tr}: переход не для состояния {st}")
            if ref(f"{mid}.{tr}.into", p["into"]):
                tgt = by_id[p["into"]]
                if tgt.get("state") not in dst_states:
                    err(f"{mid}.{tr}: цель {p['into']} в состоянии {tgt.get('state')}, ожидалось {dst_states}")
                if p["into"] == mid:
                    err(f"{mid}.{tr}: переход сам в себя")
                inv = INVERSE[tr]
                if (tr == "melt" and tgt.get("state") == "gas") or \
                        (tr == "condense" and tgt.get("state") in ("solid", "powder")):
                    inv = SUBLIM_INVERSE[tr]
                    warn(f"{mid}.{tr} → {p['into']}: сублимация/десублимация, ядро должно разрешать этот переход")
                back = tgt.get(inv)
                if isinstance(back, dict) and back.get("into") == mid:
                    if back.get("temp") != p["temp"]:
                        err(f"{mid}.{tr} ({p['temp']}) и {p['into']}.{inv} ({back.get('temp')}): температуры не совпадают")
                    if back.get("latent") != p["latent"]:
                        err(f"{mid}.{tr} ({p['latent']}) и {p['into']}.{inv} ({back.get('latent')}): скрытые теплоты не совпадают")
                elif tr in ("melt", "boil"):
                    warn(f"{mid}.{tr} → {p['into']}: обратного перехода в {mid} нет (односторонний)")
        lo = mt["freeze"]["temp"] if isinstance(mt.get("freeze"), dict) else None
        hi = mt["boil"]["temp"] if isinstance(mt.get("boil"), dict) else None
        if is_num(lo) and is_num(hi) and lo >= hi:
            err(f"{mid}: freeze.temp ≥ boil.temp")

        # Начальная температура в пределах своего состояния
        t0 = mt.get("initial_temp", ambient)
        if "fixed_temp" in mt:
            t0 = mt["fixed_temp"]
        if is_num(t0):
            for tr, cmp_hi in (("melt", True), ("boil", True), ("freeze", False), ("condense", False)):
                p = mt.get(tr)
                if isinstance(p, dict) and is_num(p.get("temp")):
                    if cmp_hi and t0 >= p["temp"]:
                        err(f"{mid}: initial_temp {t0} ≥ {tr}.temp {p['temp']} — нарисованный материал сразу сменит фазу")
                    if not cmp_hi and t0 <= p["temp"]:
                        err(f"{mid}: initial_temp {t0} ≤ {tr}.temp {p['temp']} — нарисованный материал сразу сменит фазу")

        # Тепловое расширение: плотность должна оставаться положительной в рабочем диапазоне
        beta = mt.get("thermal_expansion")
        if is_num(beta):
            if beta < 0:
                err(f"{mid}: thermal_expansion < 0")
            if st not in ("liquid", "gas", "fire", "empty"):
                warn(f"{mid}: thermal_expansion у {st} не используется")
            if st in ("gas", "fire", "empty") and not (0.8 / 293.15 <= beta <= 1.2 / 293.15):
                warn(f"{mid}: у газа β={beta}, а ожидается ≈1/293")
            tmin = -273.0 if st in ("gas", "fire", "empty") else min(
                [x for x in (lo, t0) if is_num(x)], default=t0)
            if 1 + beta * (tmin - 20) <= 0:
                err(f"{mid}: при {tmin} °C плотность по формуле density/(1+β(T−20)) становится ≤ 0")

        # Горение
        if "ignite" in mt:
            g = mt["ignite"]
            if not isinstance(g, dict):
                err(f"{mid}.ignite не объект")
            else:
                for k in ("temp", "into", "burn_time", "heat"):
                    if k not in g:
                        err(f"{mid}.ignite: нет поля {k}")
                extra = set(g) - {"temp", "into", "burn_time", "residue", "residue_chance", "heat"}
                if extra:
                    err(f"{mid}.ignite: неизвестные поля {sorted(extra)}")
                if "into" in g:
                    ref(f"{mid}.ignite.into", g["into"])
                if "burn_time" in g and (not pair(g["burn_time"]) or g["burn_time"][0] <= 0):
                    err(f"{mid}.ignite.burn_time должен быть [min, max] > 0")
                if "residue" in g:
                    ref(f"{mid}.ignite.residue", g["residue"])
                if "residue_chance" in g and not in01(g["residue_chance"]):
                    err(f"{mid}.ignite.residue_chance вне 0..1")
                if not is_num(g.get("heat", 0)) or g.get("heat", 0) < 0:
                    err(f"{mid}.ignite.heat должно быть ≥ 0")
                if not is_num(g.get("temp", 0)):
                    err(f"{mid}.ignite.temp не число")
                elif is_num(t0) and t0 >= g["temp"]:
                    err(f"{mid}: initial_temp ≥ ignite.temp")
        if "explosive" in mt:
            x = mt["explosive"]
            if not isinstance(x, dict) or set(x) != {"temp", "radius", "energy", "into"}:
                err(f"{mid}.explosive: нужны поля temp, radius, energy, into")
            else:
                if not isinstance(x["radius"], int) or x["radius"] <= 0:
                    err(f"{mid}.explosive.radius — целое > 0")
                if not is_num(x["energy"]) or x["energy"] <= 0:
                    err(f"{mid}.explosive.energy > 0")
                ref(f"{mid}.explosive.into", x["into"])
        if "acid" in mt:
            a = mt["acid"]
            if not isinstance(a, dict) or set(a) != {"strength", "into", "consumed_chance"}:
                err(f"{mid}.acid: нужны поля strength, into, consumed_chance")
            else:
                if not in01(a["strength"]) or not in01(a["consumed_chance"]):
                    err(f"{mid}.acid: strength и consumed_chance в 0..1")
                ref(f"{mid}.acid.into", a["into"])
                if mt.get("acid_resistance", 0) < 1:
                    warn(f"{mid}: кислота без acid_resistance 1 растворит сама себя")

        # Ядерные свойства
        if "nuclear" in mt:
            n = mt["nuclear"]
            if not isinstance(n, dict):
                err(f"{mid}.nuclear не объект")
                continue
            extra = set(n) - NUC_KEYS
            if extra:
                err(f"{mid}.nuclear: неизвестные поля {sorted(extra)}")
            for k in NUC_PROB:
                if k in n and not in01(n[k]):
                    err(f"{mid}.nuclear.{k} вне 0..1")
            for k in ("spontaneous", "decay_heat", "fission_energy"):
                if k in n and (not is_num(n[k]) or n[k] < 0):
                    err(f"{mid}.nuclear.{k} должно быть ≥ 0")
            g = lambda k: n.get(k, 0) if is_num(n.get(k, 0)) else 0
            if g("fissile") + g("absorb") + g("moderate") + g("reflect") > 1.0 + 1e-9:
                err(f"{mid}.nuclear: fissile+absorb+moderate+reflect > 1")
            if g("fast_fission") + g("absorb") + g("moderate") + g("reflect") > 1.0 + 1e-9:
                err(f"{mid}.nuclear: fast_fission+absorb+moderate+reflect > 1")
            fissions = g("fissile") > 0 or g("fast_fission") > 0
            if fissions:
                if g("fission_energy") <= 0:
                    err(f"{mid}.nuclear: делится, но fission_energy не задана")
                if not pair(n.get("neutrons_per_fission"), int) or n["neutrons_per_fission"][0] < 0:
                    err(f"{mid}.nuclear.neutrons_per_fission должен быть [min, max] целых")
            if "burnup_into" in n:
                ref(f"{mid}.nuclear.burnup_into", n["burnup_into"])
                if not g("burnup_chance"):
                    warn(f"{mid}.nuclear: burnup_into без burnup_chance")
            if n.get("poison_into") is not None:
                if ref(f"{mid}.nuclear.poison_into", n["poison_into"]):
                    if by_id[n["poison_into"]].get("state") not in ("gas",):
                        warn(f"{mid}.nuclear.poison_into не газ")
                if not g("poison_chance"):
                    err(f"{mid}.nuclear: poison_into без poison_chance")
    return by_id, cats


def check_reactions(doc, by_id):
    if not isinstance(doc.get("version"), int) or not isinstance(doc.get("reactions"), list):
        err("reactions.json: нужны version (int) и reactions (list)")
        return
    seen = {}
    keys = {"a", "b", "chance", "min_temp", "max_temp", "into_a", "into_b", "heat", "explode_radius", "desc"}
    for i, r in enumerate(doc["reactions"]):
        where = f"reactions[{i}]"
        if not isinstance(r, dict):
            err(f"{where} не объект")
            continue
        where = f"reactions[{i}] {r.get('a')}+{r.get('b')}"
        if set(r) - keys:
            err(f"{where}: неизвестные поля {sorted(set(r) - keys)}")
        for k in ("a", "b", "chance", "into_a", "into_b", "heat"):
            if k not in r:
                err(f"{where}: нет поля {k}")
        for k in ("a", "b"):
            if r.get(k) not in by_id:
                err(f"{where}: {k} = {r.get(k)!r} не существует")
        for k in ("into_a", "into_b"):
            v = r.get(k)
            if v is not None and v not in by_id:
                err(f"{where}: {k} = {v!r} не существует")
        if r.get("a") == r.get("b"):
            warn(f"{where}: реакция материала с самим собой")
        key = frozenset((r.get("a"), r.get("b")))
        if key in seen:
            err(f"{where}: пара уже описана в reactions[{seen[key]}]")
        seen[key] = i
        if not is_num(r.get("chance")) or r["chance"] <= 0:
            err(f"{where}: chance должен быть > 0")
        for k in ("min_temp", "max_temp"):
            if r.get(k) is not None and not is_num(r[k]):
                err(f"{where}: {k} — число или null")
        if is_num(r.get("min_temp")) and is_num(r.get("max_temp")) and r["min_temp"] > r["max_temp"]:
            err(f"{where}: min_temp > max_temp")
        if not is_num(r.get("heat", 0)):
            err(f"{where}: heat не число")
        er = r.get("explode_radius", 0)
        if not isinstance(er, int) or isinstance(er, bool) or er < 0:
            err(f"{where}: explode_radius — целое ≥ 0")
        if r.get("into_a") is None and r.get("into_b") is None:
            err(f"{where}: обе клетки не меняются — реакция повторялась бы бесконечно")
        if not isinstance(r.get("desc", ""), str):
            err(f"{where}: desc не строка")
        for k in ("a", "b"):
            m = by_id.get(r.get(k))
            if m is not None and m.get("state") == "empty":
                err(f"{where}: air не участвует в реакциях пар")


def main():
    mdoc = load("materials.json")
    rdoc = load("reactions.json")
    by_id = {}
    if isinstance(mdoc, dict):
        by_id, _ = check_materials(mdoc)
    if isinstance(rdoc, dict) and by_id:
        check_reactions(rdoc, by_id)
    for w in warnings:
        print("предупреждение:", w)
    for e in errors:
        print("ОШИБКА:", e)
    if isinstance(mdoc, dict) and isinstance(mdoc.get("materials"), list):
        counts = {}
        for mt in mdoc["materials"]:
            if isinstance(mt, dict):
                counts[mt.get("category")] = counts.get(mt.get("category"), 0) + 1
        print("материалов:", len(mdoc["materials"]), counts)
    if isinstance(rdoc, dict) and isinstance(rdoc.get("reactions"), list):
        print("реакций:", len(rdoc["reactions"]))
    print(f"ошибок: {len(errors)}, предупреждений: {len(warnings)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
