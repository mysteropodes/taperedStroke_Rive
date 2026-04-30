-- TaperedStrokeCurves: Path Effect
-- Comme TaperedStroke mais supporte les tangentes (cubicTo).
-- Les courbes de Bézier sont discrétisées en points avant traitement.
--
-- Inputs:
--   startWidth : diamètre au premier point (default 10)
--   endWidth   : diamètre au dernier point  (default 80)

type TaperedStrokeCurves = {
    startWidth: Input<number>,
    endWidth: Input<number>,
    curveSteps: Input<number>,
}

local CAP_STEPS = 32

local function getTangentAngles(ax: number, ay: number, rA: number, bx: number, by: number, rB: number): (number, number, boolean)
    local dx = bx - ax
    local dy = by - ay
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 0.001 then return 0, 0, false end
    local axisAngle = math.atan2(dy, dx)
    local sinAlpha = math.clamp((rA - rB) / dist, -1, 1)
    local alpha = math.asin(sinAlpha)
    local offset = math.pi / 2 - alpha
    return axisAngle + offset, axisAngle - offset, true
end

-- Évalue un point sur une courbe cubique de Bézier
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
    -- Discrétiser le path en points (moveTo, lineTo, cubicTo → points)
    local points: { Vector } = {}
    local cx: number = 0
    local cy: number = 0

    for i = 1, #pathData do
        local cmd = pathData[i]
        if cmd.type == "moveTo" then
            cx = cmd[1].x
            cy = cmd[1].y
            points[#points + 1] = Vector.xy(cx, cy)
        elseif cmd.type == "lineTo" then
            cx = cmd[1].x
            cy = cmd[1].y
            points[#points + 1] = Vector.xy(cx, cy)
        elseif cmd.type == "cubicTo" then
            -- cmd[1] = control1, cmd[2] = control2, cmd[3] = end
            local c1x, c1y = cmd[1].x, cmd[1].y
            local c2x, c2y = cmd[2].x, cmd[2].y
            local ex, ey   = cmd[3].x, cmd[3].y
            -- Discrétiser la courbe (on skip le premier point car déjà ajouté)
            local curveSteps = math.max(1, math.floor(self.curveSteps))
            for j = 1, curveSteps do
                local t = j / curveSteps
                local px, py = cubicBezier(t, cx, cy, c1x, c1y, c2x, c2y, ex, ey)
                points[#points + 1] = Vector.xy(px, py)
            end
            cx = ex
            cy = ey
        end
    end

    local n = #points
    if n < 2 then return pathData end

    local rStart = math.max(self.startWidth * 0.5, 0.001)
    local rEnd   = math.max(self.endWidth   * 0.5, 0.001)

    -- Rayon interpolé à chaque point selon distance cumulée
    local lengths: { number } = { 0 }
    for i = 2, n do
        local px = points[i].x - points[i-1].x
        local py = points[i].y - points[i-1].y
        lengths[i] = lengths[i-1] + math.sqrt(px*px + py*py)
    end
    local totalLen = lengths[n]

    local radii: { number } = {}
    for i = 1, n do
        local t = if totalLen > 0 then lengths[i] / totalLen else 0
        radii[i] = rStart + (rEnd - rStart) * t
    end

    -- Angles de tangence pour chaque segment
    local segAngL: { number } = {}
    local segAngR: { number } = {}
    for i = 1, n - 1 do
        local angL, angR, _ = getTangentAngles(
            points[i].x, points[i].y, radii[i],
            points[i+1].x, points[i+1].y, radii[i+1]
        )
        segAngL[i] = angL
        segAngR[i] = angR
    end

    local dst = Path.new()

    local p0 = points[1]
    local r0 = radii[1]
    local firstAngL = segAngL[1]
    local _firstAngR = segAngR[1]

    dst:moveTo(Vector.xy(p0.x + math.cos(firstAngL) * r0, p0.y + math.sin(firstAngL) * r0))

    -- Demi-cercle du premier point, sens anti-horaire
    for i = 1, CAP_STEPS do
        local t = i / CAP_STEPS
        local a = firstAngL + math.pi * t
        dst:lineTo(Vector.xy(p0.x + math.cos(a) * r0, p0.y + math.sin(a) * r0))
    end

    -- Bord droit : point 1 → point N
    for i = 1, n - 1 do
        local bx, by = points[i+1].x, points[i+1].y
        local rB = radii[i+1]
        local angR = segAngR[i]
        dst:lineTo(Vector.xy(bx + math.cos(angR) * rB, by + math.sin(angR) * rB))

        if i < n - 1 then
            local nextAngR = segAngR[i+1]
            local diff = nextAngR - angR
            while diff < 0 do diff = diff + 2 * math.pi end
            while diff > 2 * math.pi do diff = diff - 2 * math.pi end
            local arcSteps = math.max(1, math.floor(diff / math.pi * CAP_STEPS))
            for j = 1, arcSteps do
                local t = j / arcSteps
                local a = angR + diff * t
                dst:lineTo(Vector.xy(bx + math.cos(a) * rB, by + math.sin(a) * rB))
            end
        end
    end

    -- Demi-cercle du dernier point, sens anti-horaire
    local pN = points[n]
    local rN = radii[n]
    local lastAngR = segAngR[n-1]
    for i = 1, CAP_STEPS do
        local t = i / CAP_STEPS
        local a = lastAngR + math.pi * t
        dst:lineTo(Vector.xy(pN.x + math.cos(a) * rN, pN.y + math.sin(a) * rN))
    end

    -- Bord gauche : point N → point 1
    for i = n - 1, 1, -1 do
        local ax, ay = points[i].x, points[i].y
        local rA = radii[i]
        local angL = segAngL[i]
        dst:lineTo(Vector.xy(ax + math.cos(angL) * rA, ay + math.sin(angL) * rA))

        if i > 1 then
            local prevAngL = segAngL[i-1]
            local diff = prevAngL - angL
            while diff < 0 do diff = diff + 2 * math.pi end
            while diff > 2 * math.pi do diff = diff - 2 * math.pi end
            local arcSteps = math.max(1, math.floor(diff / math.pi * CAP_STEPS))
            for j = 1, arcSteps do
                local t = j / arcSteps
                local a = angL + diff * t
                dst:lineTo(Vector.xy(ax + math.cos(a) * rA, ay + math.sin(a) * rA))
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
        update     = update,
    }
end
