package main

import (
	"errors"
	"fmt"
	"math"
	"time"
)

const (
	earthRadiusKm   = 6371.0
	equatorRadiusKm = 6378.137
	earthMu         = 398600.4418
	earthJ2         = 1.08262668e-3
	wgs84E2         = 6.69437999014e-3

	orbitFitWindow   = 24 * time.Hour
	orbitPlaneWindow = 3 * time.Hour
	orbitMinSpan     = time.Hour
	orbitMinPoints   = 20
	planePairMin     = 15 * 60.0
	planePairMax     = 35 * 60.0

	passSearchHorizon = 48 * time.Hour
	passSearchStep    = 10.0
	passTrackStep     = 15.0
)

var errNotEnoughData = errors.New("not enough position history for a prediction")

type vec3 struct{ X, Y, Z float64 }

func (a vec3) add(b vec3) vec3      { return vec3{a.X + b.X, a.Y + b.Y, a.Z + b.Z} }
func (a vec3) scale(k float64) vec3 { return vec3{a.X * k, a.Y * k, a.Z * k} }
func (a vec3) dot(b vec3) float64   { return a.X*b.X + a.Y*b.Y + a.Z*b.Z }
func (a vec3) length() float64      { return math.Sqrt(a.dot(a)) }
func (a vec3) unit() vec3           { return a.scale(1 / a.length()) }
func (a vec3) cross(b vec3) vec3 {
	return vec3{a.Y*b.Z - a.Z*b.Y, a.Z*b.X - a.X*b.Z, a.X*b.Y - a.Y*b.X}
}
func (a vec3) rotateZ(angle float64) vec3 {
	c, s := math.Cos(angle), math.Sin(angle)
	return vec3{c*a.X - s*a.Y, s*a.X + c*a.Y, a.Z}
}

type observation struct {
	t        float64
	r        vec3
	altitude float64
}

func newObservation(unix, lat, lon, altitude float64) observation {
	phi := radians(lat)
	geocentric := math.Atan2((1-wgs84E2)*math.Sin(phi), math.Cos(phi))
	alpha := radians(lon) + gmst(unix)
	return observation{
		t:        unix,
		r:        vec3{math.Cos(geocentric) * math.Cos(alpha), math.Cos(geocentric) * math.Sin(alpha), math.Sin(geocentric)},
		altitude: altitude,
	}
}

type orbitModel struct {
	refTime     float64
	node        vec3
	inPlane     vec3
	u0          float64
	rate        float64
	nodeRate    float64
	inclination float64
	altitude    float64
	points      int
	span        float64
}

func fitOrbit(obs []observation) (*orbitModel, error) {
	span := 0.0
	if len(obs) > 0 {
		span = obs[len(obs)-1].t - obs[0].t
	}
	if len(obs) < orbitMinPoints || span < orbitMinSpan.Seconds() {
		return nil, fmt.Errorf("%w: have %d positions over %s, need at least %d over %s",
			errNotEnoughData, len(obs), time.Duration(span*float64(time.Second)).Round(time.Minute), orbitMinPoints, orbitMinSpan)
	}

	m := &orbitModel{refTime: obs[len(obs)-1].t, points: len(obs), span: span}
	for _, o := range obs {
		m.altitude += o.altitude
	}
	m.altitude /= float64(len(obs))
	m.rate = math.Sqrt(earthMu / math.Pow(equatorRadiusKm+m.altitude, 3))

	for i := 0; i < 3; i++ {
		normal, err := m.fitPlane(obs)
		if err != nil {
			return nil, err
		}
		m.node = vec3{-normal.Y, normal.X, 0}.unit()
		m.inPlane = normal.cross(m.node)
		m.inclination = math.Acos(normal.Z)
		m.fitPhase(obs)
		a := math.Cbrt(earthMu / (m.rate * m.rate))
		m.nodeRate = -1.5 * m.rate * earthJ2 * math.Pow(equatorRadiusKm/a, 2) * math.Cos(m.inclination)
	}
	return m, nil
}

func (m *orbitModel) toRefPlane(o observation) vec3 {
	return o.r.rotateZ(m.nodeRate * (m.refTime - o.t))
}

func (m *orbitModel) fitPlane(obs []observation) (vec3, error) {
	from := m.refTime - orbitPlaneWindow.Seconds()
	corrected := make([]vec3, len(obs))
	for i, o := range obs {
		corrected[i] = m.toRefPlane(o)
	}

	var sum vec3
	for j := range obs {
		if obs[j].t < from {
			continue
		}
		for k := j + 1; k < len(obs); k++ {
			dt := obs[k].t - obs[j].t
			if dt < planePairMin {
				continue
			}
			if dt > planePairMax {
				break
			}
			sum = sum.add(corrected[j].cross(corrected[k]))
		}
	}
	if sum.length() == 0 {
		return vec3{}, fmt.Errorf("%w: no positions %s-%s apart within the last %s",
			errNotEnoughData, time.Duration(planePairMin)*time.Second, time.Duration(planePairMax)*time.Second, orbitPlaneWindow)
	}
	return sum.unit(), nil
}

func (m *orbitModel) fitPhase(obs []observation) {
	xs := make([]float64, len(obs))
	us := make([]float64, len(obs))
	var meanX, meanU float64
	for i, o := range obs {
		r := m.toRefPlane(o)
		u := math.Atan2(r.dot(m.inPlane), r.dot(m.node))
		if i > 0 {
			expected := us[i-1] + m.rate*(o.t-obs[i-1].t)
			u = expected + wrapPi(u-expected)
		}
		xs[i], us[i] = o.t-m.refTime, u
		meanX += xs[i]
		meanU += u
	}
	meanX /= float64(len(obs))
	meanU /= float64(len(obs))

	var sxx, sxu float64
	for i := range xs {
		dx := xs[i] - meanX
		sxx += dx * dx
		sxu += dx * (us[i] - meanU)
	}
	m.rate = sxu / sxx
	m.u0 = meanU - m.rate*meanX
}

func (m *orbitModel) position(t float64) (lat, lon float64) {
	dt := t - m.refTime
	u := m.u0 + m.rate*dt
	rot := m.nodeRate * dt
	r := m.node.rotateZ(rot).scale(math.Cos(u)).add(m.inPlane.rotateZ(rot).scale(math.Sin(u)))
	geocentric := math.Asin(math.Max(-1, math.Min(1, r.Z)))
	lat = degrees(math.Atan2(math.Sin(geocentric), (1-wgs84E2)*math.Cos(geocentric)))
	lon = wrap180(degrees(math.Atan2(r.Y, r.X) - gmst(t)))
	return lat, lon
}

func (m *orbitModel) distanceKm(t float64, loc Location) float64 {
	lat, lon := m.position(t)
	return haversineKm(lat, lon, loc.Latitude, loc.Longitude)
}

func (m *orbitModel) nextPass(now float64, loc Location) (bool, *passInfo) {
	inside := func(t float64) bool { return m.distanceKm(t, loc) <= loc.RadiusKm }
	horizon := now + passSearchHorizon.Seconds()

	overhead := inside(now)
	t := now
	for inside(t) {
		if t += passSearchStep; t > horizon {
			return overhead, nil
		}
	}
	for !inside(t) {
		if t += passSearchStep; t > horizon {
			return overhead, nil
		}
	}
	_, start := bisect(t-passSearchStep, t, inside)
	for inside(t) {
		t += passSearchStep
	}
	end, _ := bisect(t-passSearchStep, t, inside)

	p := &passInfo{Start: int64(math.Round(start)), End: int64(math.Round(end)), MinDistanceKm: math.Inf(1)}
	for s := start; s <= end; s++ {
		if d := m.distanceKm(s, loc); d < p.MinDistanceKm {
			p.MinDistanceKm, p.Closest = d, int64(math.Round(s))
		}
	}
	p.MaxElevationDeg = elevationDeg(p.MinDistanceKm, m.altitude)
	for s := start; ; s += passTrackStep {
		s = math.Min(s, end)
		lat, lon := m.position(s)
		p.Track = append(p.Track, [2]float64{lat, lon})
		if s == end {
			break
		}
	}
	return overhead, p
}

func (m *orbitModel) summary() *orbitSummary {
	return &orbitSummary{
		Points:         m.points,
		SpanHours:      m.span / 3600,
		PeriodMinutes:  2 * math.Pi / m.rate / 60,
		InclinationDeg: degrees(m.inclination),
		LastObserved:   int64(m.refTime),
	}
}

func bisect(lo, hi float64, f func(float64) bool) (float64, float64) {
	want := f(hi)
	for hi-lo > 1 {
		mid := (lo + hi) / 2
		if f(mid) == want {
			hi = mid
		} else {
			lo = mid
		}
	}
	return lo, hi
}

func gmst(unix float64) float64 {
	days := unix/86400 - 10957.5
	return math.Mod(radians(280.46061837+360.98564736629*days), 2*math.Pi)
}

func haversineKm(lat1, lon1, lat2, lon2 float64) float64 {
	dLat := radians(lat2 - lat1)
	dLon := radians(lon2 - lon1)
	h := math.Pow(math.Sin(dLat/2), 2) + math.Cos(radians(lat1))*math.Cos(radians(lat2))*math.Pow(math.Sin(dLon/2), 2)
	return 2 * earthRadiusKm * math.Asin(math.Min(1, math.Sqrt(h)))
}

func elevationDeg(groundDistanceKm, altitudeKm float64) float64 {
	gamma := groundDistanceKm / earthRadiusKm
	return degrees(math.Atan2(math.Cos(gamma)-earthRadiusKm/(earthRadiusKm+altitudeKm), math.Sin(gamma)))
}

func radians(deg float64) float64 { return deg * math.Pi / 180 }
func degrees(rad float64) float64 { return rad * 180 / math.Pi }
func wrapPi(a float64) float64    { return a - 2*math.Pi*math.Round(a/(2*math.Pi)) }
func wrap180(deg float64) float64 { return deg - 360*math.Round(deg/360) }
