-- TaperedStrokeCurves: Path Effect
-- Comme TaperedStroke mais supporte les tangentes (cubicTo).
-- Les courbes de Bézier sont discrétisées en points avant traitement.
-- startWidth est ancré sur le premier point du path, endWidth sur le dernier.
--
-- Inputs:
--   startWidth : diamètre au premier point (default 10)
--   endWidth   : diamètre au dernier point  (default 80)
--   flip       : inverse manuellement startWidth/endWidth si la polarité est incorrecte

type TaperedStrokeCurves = {
    startWidth: Input<number>,
    endWidth: Input<number>,
    curveSteps: Input<number>,
    flip: Input<boolean>,
    -- Ancres de position : data-binder le 1er ET le dernier sommet authored
    -- (via le view model). Quand useAnchor=true, on compare le VECTEUR
    -- ancreStart→ancreEnd au vecteur idx1→idxN : la translation entre l'espace
    -- du sommet et celui de l'effet s'annule dans la différence → stable malgré
    -- le réordre de Rive, sans état, sans avoir à connaître la transformation.
    useAnchor: Input<boolean>,
    anchorStartX: Input<number>,
    anchorStartY: Input<number>,
    anchorEndX: Input<number>,
    anchorEndY: Input<number>,
    -- Trim path (pourcentages 0..100 de la longueur, dans l'orientation ancrée)
    trimStart: Input<number>,
    trimEnd: Input<number>,
    trimOffset: Input<number>,
    debug: Input<boolean>,
}

local CAP_STEPS = 32
local TWO_PI = 2 * math.pi

local loggedSwap = false  -- pour n'imprimer le debug qu'au changement de sens
local dbgInit = false

local function wrapPi(a: number): number
    a = a % TWO_PI
    if a > math.pi then a = a - TWO_PI end
    if a <= -math.pi then a = a + TWO_PI end
    return a
end

-- Delta signé pour aller de a0 à a1 en passant par la direction "via".
-- Sert à dessiner un cap rond qui contourne le bon côté de l'endpoint.
local function capDelta(a0: number, a1: number, via: number): number
    local d = wrapPi(a1 - a0)
    local dv = wrapPi(via - a0)
    if (d >= 0) ~= (dv >= 0) then
        if d >= 0 then d = d - TWO_PI else d = d + TWO_PI end
    end
    return d
end

local function getTangentAngles(ax: number, ay: number, rA: number, bx: number, by: number, rB: number): (number, number)
    local dx = bx - ax
    local dy = by - ay
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 0.001 then return 0, 0 end
    local axisAngle = math.atan2(dy, dx)
    local sinAlpha = math.clamp((rA - rB) / dist, -1, 1)
    local alpha = math.asin(sinAlpha)
    local offset = math.pi / 2 - alpha
    return axisAngle + offset, axisAngle - offset
end

local function cubicBezier(t: number, p0x: number, p0y: number, c1x: number, c1y: number, c2x: number, c2y: number, p1x: number, p1y: number): (number, number)
    local mt = 1 - t
    local mt2 = mt * mt
    local mt3 = mt2 * mt
    local t2 = t * t
    local t3 = t2 * t
    local x = mt3 * p0x + 3 * mt2 * t * c1x + 3 * mt * t2 * c2x + t3 * p1x
    local y = mt3 * p0y + 3 * mt2 * t * c1y + 3 * mt * t2 * c2y + t3 * p1y
    return x, y
end

function update(self: TaperedStrokeCurves, pathData: PathData, node: NodeReadData): PathData
    local numCmds = #pathData
    if numCmds < 2 then return pathData end

    local rStart = math.max(self.startWidth * 0.5, 0.001)
    local rEnd   = math.max(self.endWidth   * 0.5, 0.001)

    -- Compter uniquement les commandes géométriques (pas close)
    local numGeomCmds = 0
    for i = 1, numCmds do
        local t = pathData[i].type
        if t == "moveTo" or t == "lineTo" or t == "cubicTo" then
            numGeomCmds = numGeomCmds + 1
        end
    end
    if numGeomCmds < 2 then return pathData end

    -- ── 1) Discrétiser le path (positions seules, indépendant du sens) ────────
    -- geomPos[i] = index géométrique continu (0 .. numGeomCmds-1) du point i,
    -- pour interpoler le rayon ensuite, une fois le sens connu.
    local points: { Vector } = {}
    local geomPos: { number } = {}
    local cx: number = 0
    local cy: number = 0
    local geomIdx: number = 0

    for i = 1, numCmds do
        local cmd = pathData[i]
        if cmd.type == "close" then continue end
        geomIdx = geomIdx + 1

        if cmd.type == "moveTo" or cmd.type == "lineTo" then
            cx = cmd[1].x
            cy = cmd[1].y
            points[#points + 1] = Vector.xy(cx, cy)
            geomPos[#geomPos + 1] = geomIdx - 1
        elseif cmd.type == "cubicTo" then
            local c1x, c1y = cmd[1].x, cmd[1].y
            local c2x, c2y = cmd[2].x, cmd[2].y
            local ex, ey   = cmd[3].x, cmd[3].y
            local curveSteps = math.max(1, math.floor(self.curveSteps))
            for j = 1, curveSteps do
                local t = j / curveSteps
                local px, py = cubicBezier(t, cx, cy, c1x, c1y, c2x, c2y, ex, ey)
                points[#points + 1] = Vector.xy(px, py)
                geomPos[#geomPos + 1] = (geomIdx - 2) + t  -- prev cmd → cmd courante
            end
            cx = ex
            cy = ey
        end
    end

    local n = #points
    if n < 2 then return pathData end

    -- ── 2) Sens ───────────────────────────────────────────────────────────────
    -- Deux modes :
    --  • useAnchor=true  : on ancre startWidth sur l'endpoint le plus PROCHE de
    --    (anchorX, anchorY). Si cette ancre est data-bindée sur la position du
    --    1er sommet authored (via le view model), elle est STABLE malgré le
    --    réordre de Rive → plus de flip, sans état ni oscillation. `flip` reste
    --    dispo pour inverser le sens si on a bindé le dernier sommet au lieu du 1er.
    --  • useAnchor=false : ordre brut de pathData (index 1 = start) + `flip` manuel.
    local swapDir = false
    local dex, dey, dax, day = 0.0, 0.0, 0.0, 0.0  -- pour debug
    if self.useAnchor then
        -- vecteur idx1→idxN (espace effet) vs vecteur ancreStart→ancreEnd (espace
        -- sommet). La translation s'annule dans la différence ; on choisit
        -- l'appariement dont le vecteur pointe dans le même sens.
        local p1 = points[1]
        local pN = points[n]
        dex = pN.x - p1.x; dey = pN.y - p1.y
        dax = self.anchorEndX - self.anchorStartX
        day = self.anchorEndY - self.anchorStartY
        local keepErr = (dex - dax) * (dex - dax) + (dey - day) * (dey - day)
        local swapErr = (dex + dax) * (dex + dax) + (dey + day) * (dey + day)
        swapDir = swapErr < keepErr   -- si le vecteur est mieux inversé → swap
    end
    if self.flip then swapDir = not swapDir end

    local effStart = if swapDir then rEnd   else rStart
    local effEnd   = if swapDir then rStart else rEnd

    -- ── 3) Affecter les rayons selon le sens choisi ───────────────────────────
    local radii: { number } = {}
    for i = 1, n do
        radii[i] = effStart + (effEnd - effStart) * (geomPos[i] / (numGeomCmds - 1))
    end

    -- ── 3b) Brider au rayon de courbure local ─────────────────────────────────
    -- Si la demi-largeur dépasse le rayon de courbure du tracé, le bord intérieur
    -- de l'offset se replie sur lui-même → Rive le rend comme un trou (croissant).
    -- On limite donc radii[i] au rayon du cercle circonscrit aux 3 points voisins
    -- (× 0.95 de marge pour éviter le rebroussement). Le stroke s'amincit donc
    -- automatiquement dans les virages trop serrés, mais reste propre (sans trou).
    -- stencil élargi (k points d'écart) pour estimer la courbure sans bruit :
    -- trois échantillons adjacents sont presque alignés → aire minuscule → rayon
    -- de courbure erratique. On prend des points plus espacés le long du tracé.
    local curveSteps = math.max(1, math.floor(self.curveSteps))
    local k = math.max(1, math.floor(curveSteps / 4))
    for i = 1, n do
        local ia = math.max(1, i - k)
        local ic = math.min(n, i + k)
        if ic - ia >= 2 then
            local ax = points[ia].x; local ay = points[ia].y
            local bx = points[i].x;  local by = points[i].y
            local cx2 = points[ic].x; local cy2 = points[ic].y
            local area2 = math.abs((bx - ax) * (cy2 - ay) - (cx2 - ax) * (by - ay))
            if area2 > 0.0001 then
                local ab = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay))
                local bc = math.sqrt((cx2 - bx) * (cx2 - bx) + (cy2 - by) * (cy2 - by))
                local ca = math.sqrt((ax - cx2) * (ax - cx2) + (ay - cy2) * (ay - cy2))
                local rCurv = (ab * bc * ca) / (2 * area2)
                local rMax = rCurv * 0.95
                if radii[i] > rMax then radii[i] = rMax end
            end
        end
    end

    -- extrémités : le stencil y est dégénéré, on clampe explicitement au voisin
    -- pour que le cap ne dépasse pas le corps adjacent (sinon spike/bec au cap).
    if radii[1] > radii[2] then radii[1] = radii[2] end
    if radii[n] > radii[n-1] then radii[n] = radii[n-1] end

    -- lissage des rayons (2 passes) pour supprimer tout décrochage brutal de
    -- largeur introduit par le bridage → évite les spikes/becs aux raccords.
    for _pass = 1, 2 do
        local sm: { number } = {}
        sm[1] = radii[1]; sm[n] = radii[n]
        for i = 2, n - 1 do
            sm[i] = (radii[i-1] + 2 * radii[i] + radii[i+1]) * 0.25
        end
        for i = 1, n do radii[i] = sm[i] end
    end

    -- ── 4) Trim path (longueur d'arc, dans l'orientation ancrée) ──────────────
    -- On garde la portion [trimStart, trimEnd] (+ trimOffset) du tracé. Le taper
    -- reste ancré au tracé COMPLET (le trim révèle une sous-portion de la forme).
    -- Mesuré dans l'orientation ancrée (mirroir si swapDir) → ne flippe pas.
    do
        local a = (self.trimStart + self.trimOffset) / 100
        local b = (self.trimEnd + self.trimOffset) / 100
        if a < 0 then a = 0 elseif a > 1 then a = 1 end
        if b < 0 then b = 0 elseif b > 1 then b = 1 end

        if b <= a + 0.0001 then
            return Path.new()  -- rien à dessiner
        end

        if a > 0.0001 or b < 0.9999 then
            -- longueur cumulée le long des points
            local cum: { number } = {}
            cum[1] = 0
            for i = 2, n do
                local dx = points[i].x - points[i-1].x
                local dy = points[i].y - points[i-1].y
                cum[i] = cum[i-1] + math.sqrt(dx * dx + dy * dy)
            end
            local S = cum[n]

            if S > 0.0001 then
                -- mirroir si orientation inversée → trim relatif au vrai départ
                local d0: number, d1: number
                if swapDir then d0 = (1 - b) * S; d1 = (1 - a) * S
                else d0 = a * S; d1 = b * S end

                local function sampleAt(d: number): (number, number, number)
                    if d <= 0 then return points[1].x, points[1].y, radii[1] end
                    if d >= S then return points[n].x, points[n].y, radii[n] end
                    for j = 1, n - 1 do
                        if cum[j+1] >= d then
                            local seg = cum[j+1] - cum[j]
                            local t = if seg > 0.0001 then (d - cum[j]) / seg else 0
                            return points[j].x + (points[j+1].x - points[j].x) * t,
                                   points[j].y + (points[j+1].y - points[j].y) * t,
                                   radii[j] + (radii[j+1] - radii[j]) * t
                        end
                    end
                    return points[n].x, points[n].y, radii[n]
                end

                local np: { Vector } = {}
                local nr: { number } = {}
                local sx, sy, sr = sampleAt(d0)
                np[1] = Vector.xy(sx, sy); nr[1] = sr
                for i = 1, n do
                    if cum[i] > d0 + 0.0001 and cum[i] < d1 - 0.0001 then
                        np[#np + 1] = points[i]; nr[#nr + 1] = radii[i]
                    end
                end
                local ex2, ey2, er = sampleAt(d1)
                np[#np + 1] = Vector.xy(ex2, ey2); nr[#nr + 1] = er

                points = np
                radii = nr
                n = #points
            end
        end
    end

    if n < 2 then return Path.new() end

    if self.debug and ((not dbgInit) or swapDir ~= loggedSwap) then
        dbgInit = true
        loggedSwap = swapDir
        print("swapDir=" .. tostring(swapDir)
            .. " | vecEffet=(" .. dex .. "," .. dey .. ")"
            .. " vecAncre=(" .. dax .. "," .. day .. ")")
    end

    -- Angles de tangence + axe pour chaque segment
    local segAngL: { number } = {}
    local segAngR: { number } = {}
    local segAxis: { number } = {}
    for i = 1, n - 1 do
        local dx = points[i+1].x - points[i].x
        local dy = points[i+1].y - points[i].y
        segAxis[i] = math.atan2(dy, dx)
        local angL, angR = getTangentAngles(
            points[i].x, points[i].y, radii[i],
            points[i+1].x, points[i+1].y, radii[i+1]
        )
        segAngL[i] = angL
        segAngR[i] = angR
    end

    local dst = Path.new()

    local p0 = points[1]
    local r0 = radii[1]
    local angL1 = segAngL[1]
    local angR1 = segAngR[1]

    -- Démarrage sur le point de tangence gauche du premier point
    dst:moveTo(Vector.xy(p0.x + math.cos(angL1) * r0, p0.y + math.sin(angL1) * r0))

    -- Cap de départ : arc rond du tangent gauche au tangent droit,
    -- en contournant l'ARRIÈRE du premier point (direction axe + π).
    -- Span = π + 2·alpha (et non π fixe) → cap parfaitement rond, sans gap.
    do
        local dCap = capDelta(angL1, angR1, segAxis[1] + math.pi)
        for i = 1, CAP_STEPS do
            local a = angL1 + dCap * (i / CAP_STEPS)
            dst:lineTo(Vector.xy(p0.x + math.cos(a) * r0, p0.y + math.sin(a) * r0))
        end
    end

    -- Bord droit : point 1 → point N
    for i = 1, n - 1 do
        local bx, by = points[i+1].x, points[i+1].y
        local rB = radii[i+1]
        local angR = segAngR[i]
        dst:lineTo(Vector.xy(bx + math.cos(angR) * rB, by + math.sin(angR) * rB))

        if i < n - 1 then
            local diff = wrapPi(segAngR[i+1] - angR)
            if math.abs(diff) > 0.001 then
                local arcSteps = math.max(1, math.floor(math.abs(diff) / math.pi * CAP_STEPS))
                for j = 1, arcSteps do
                    local a = angR + diff * (j / arcSteps)
                    dst:lineTo(Vector.xy(bx + math.cos(a) * rB, by + math.sin(a) * rB))
                end
            end
        end
    end

    -- Cap de fin : arc rond du tangent droit au tangent gauche du dernier point,
    -- en contournant l'AVANT (direction axe du dernier segment). Span = π - 2·alpha.
    local pN = points[n]
    local rN = radii[n]
    local angRlast = segAngR[n-1]
    local angLlast = segAngL[n-1]
    do
        local dCap = capDelta(angRlast, angLlast, segAxis[n-1])
        for i = 1, CAP_STEPS do
            local a = angRlast + dCap * (i / CAP_STEPS)
            dst:lineTo(Vector.xy(pN.x + math.cos(a) * rN, pN.y + math.sin(a) * rN))
        end
    end

    -- Bord gauche : point N → point 1
    for i = n - 1, 1, -1 do
        local ax, ay = points[i].x, points[i].y
        local rA = radii[i]
        local angL = segAngL[i]
        dst:lineTo(Vector.xy(ax + math.cos(angL) * rA, ay + math.sin(angL) * rA))

        if i > 1 then
            local diff = wrapPi(segAngL[i-1] - angL)
            if math.abs(diff) > 0.001 then
                local arcSteps = math.max(1, math.floor(math.abs(diff) / math.pi * CAP_STEPS))
                for j = 1, arcSteps do
                    local a = angL + diff * (j / arcSteps)
                    dst:lineTo(Vector.xy(ax + math.cos(a) * rA, ay + math.sin(a) * rA))
                end
            end
        end
    end

    dst:close()

    return dst
end

return function(): PathEffect<TaperedStrokeCurves>
    return {
        startWidth = 10,
        endWidth   = 80,
        curveSteps = 20,
        flip         = false,
        useAnchor    = false,
        anchorStartX = 0,
        anchorStartY = 0,
        anchorEndX   = 0,
        anchorEndY   = 0,
        trimStart    = 0,
        trimEnd      = 100,
        trimOffset   = 0,
        debug        = false,
        update     = update,
    }
end
