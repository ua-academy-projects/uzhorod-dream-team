package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/lib/pq"
	"github.com/redis/go-redis/v9"
)

type SessionStore interface {
	Theme(ctx context.Context, sessionID string) (string, error)
	SetTheme(ctx context.Context, sessionID, theme string) error
	Location(ctx context.Context, sessionID string) (*Location, error)
	SetLocation(ctx context.Context, sessionID string, loc Location) error
}

func newSessionStore() SessionStore {
	switch cfg.SessionBackend {
	case "postgres":
		store := postgresSessions{db: db, ttl: cfg.SessionTTL}
		go store.deleteExpired()
		slog.Info("sessions stored in postgres", "ttl", cfg.SessionTTL)
		return store
	case "hstore":
		slog.Info("sessions stored in unlogged hstore table, expired by pg_cron",
			"table", "kv_sessions", "ttl", cfg.SessionTTL)
		return hstoreSessions{db: db, ttl: cfg.SessionTTL}
	}

	client := redis.NewClient(&redis.Options{
		Addr:     cfg.RedisAddr,
		Password: cfg.RedisPassword,
	})
	if err := client.Ping(ctx).Err(); err != nil {
		slog.Warn("redis not reachable, settings will fall back to defaults", "addr", cfg.RedisAddr, "err", err)
	} else {
		slog.Info("redis connected", "addr", cfg.RedisAddr)
	}
	return redisSessions{client: client, ttl: cfg.SessionTTL}
}

type redisSessions struct {
	client *redis.Client
	ttl    time.Duration
}

func (s redisSessions) key(sessionID, field string) string {
	return "session:" + sessionID + ":" + field
}

func (s redisSessions) Theme(ctx context.Context, sessionID string) (string, error) {
	theme, err := s.client.Get(ctx, s.key(sessionID, "theme")).Result()
	if errors.Is(err, redis.Nil) {
		return "", nil
	}
	return theme, err
}

func (s redisSessions) SetTheme(ctx context.Context, sessionID, theme string) error {
	return s.client.Set(ctx, s.key(sessionID, "theme"), theme, s.ttl).Err()
}

func (s redisSessions) Location(ctx context.Context, sessionID string) (*Location, error) {
	raw, err := s.client.Get(ctx, s.key(sessionID, "location")).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var loc Location
	if err := json.Unmarshal(raw, &loc); err != nil {
		return nil, err
	}
	return &loc, nil
}

func (s redisSessions) SetLocation(ctx context.Context, sessionID string, loc Location) error {
	raw, err := json.Marshal(loc)
	if err != nil {
		return err
	}
	return s.client.Set(ctx, s.key(sessionID, "location"), raw, s.ttl).Err()
}

type postgresSessions struct {
	db  *sql.DB
	ttl time.Duration
}

func ttlInterval(ttl time.Duration) string {
	return fmt.Sprintf("%d seconds", int64(ttl.Seconds()))
}

func (s postgresSessions) Theme(ctx context.Context, sessionID string) (string, error) {
	var theme string
	err := s.db.QueryRowContext(ctx,
		`SELECT theme FROM sessions WHERE session_id = $1 AND expires_at > now()`, sessionID).Scan(&theme)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return theme, err
}

func (s postgresSessions) SetTheme(ctx context.Context, sessionID, theme string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO sessions (session_id, theme, expires_at) VALUES ($1, $2, now() + $3::interval)
		ON CONFLICT (session_id) DO UPDATE SET theme = EXCLUDED.theme, expires_at = EXCLUDED.expires_at`,
		sessionID, theme, ttlInterval(s.ttl))
	return err
}

func (s postgresSessions) Location(ctx context.Context, sessionID string) (*Location, error) {
	var lat, lon, radius sql.NullFloat64
	err := s.db.QueryRowContext(ctx,
		`SELECT latitude, longitude, radius_km FROM sessions WHERE session_id = $1 AND expires_at > now()`,
		sessionID).Scan(&lat, &lon, &radius)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !lat.Valid || !lon.Valid || !radius.Valid {
		return nil, nil
	}
	return &Location{Latitude: lat.Float64, Longitude: lon.Float64, RadiusKm: radius.Float64}, nil
}

func (s postgresSessions) SetLocation(ctx context.Context, sessionID string, loc Location) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO sessions (session_id, theme, latitude, longitude, radius_km, expires_at)
		VALUES ($1, '', $2, $3, $4, now() + $5::interval)
		ON CONFLICT (session_id) DO UPDATE SET latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude,
			radius_km = EXCLUDED.radius_km, expires_at = EXCLUDED.expires_at`,
		sessionID, loc.Latitude, loc.Longitude, loc.RadiusKm, ttlInterval(s.ttl))
	return err
}

type hstoreSessions struct {
	db  *sql.DB
	ttl time.Duration
}

func (s hstoreSessions) merge(ctx context.Context, sessionID string, keys, values []string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO kv_sessions (session_id, data, expires_at)
		VALUES ($1, hstore($2::text[], $3::text[]), now() + $4::interval)
		ON CONFLICT (session_id) DO UPDATE SET data = kv_sessions.data || EXCLUDED.data, expires_at = EXCLUDED.expires_at`,
		sessionID, pq.Array(keys), pq.Array(values), ttlInterval(s.ttl))
	return err
}

func (s hstoreSessions) Theme(ctx context.Context, sessionID string) (string, error) {
	var theme sql.NullString
	err := s.db.QueryRowContext(ctx,
		`SELECT data -> 'theme' FROM kv_sessions WHERE session_id = $1 AND expires_at > now()`,
		sessionID).Scan(&theme)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return theme.String, err
}

func (s hstoreSessions) SetTheme(ctx context.Context, sessionID, theme string) error {
	return s.merge(ctx, sessionID, []string{"theme"}, []string{theme})
}

func (s hstoreSessions) Location(ctx context.Context, sessionID string) (*Location, error) {
	var lat, lon, radius sql.NullString
	err := s.db.QueryRowContext(ctx,
		`SELECT data -> 'latitude', data -> 'longitude', data -> 'radius_km'
		FROM kv_sessions WHERE session_id = $1 AND expires_at > now()`,
		sessionID).Scan(&lat, &lon, &radius)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !lat.Valid || !lon.Valid || !radius.Valid {
		return nil, nil
	}

	var loc Location
	for _, f := range []struct {
		raw string
		dst *float64
	}{{lat.String, &loc.Latitude}, {lon.String, &loc.Longitude}, {radius.String, &loc.RadiusKm}} {
		if *f.dst, err = strconv.ParseFloat(f.raw, 64); err != nil {
			return nil, err
		}
	}
	return &loc, nil
}

func (s hstoreSessions) SetLocation(ctx context.Context, sessionID string, loc Location) error {
	return s.merge(ctx, sessionID,
		[]string{"latitude", "longitude", "radius_km"},
		[]string{
			strconv.FormatFloat(loc.Latitude, 'f', -1, 64),
			strconv.FormatFloat(loc.Longitude, 'f', -1, 64),
			strconv.FormatFloat(loc.RadiusKm, 'f', -1, 64),
		})
}

func (s postgresSessions) deleteExpired() {
	for {
		result, err := s.db.Exec(`DELETE FROM sessions WHERE expires_at <= now()`)
		if err != nil {
			slog.Warn("expired sessions cleanup failed", "err", err)
		} else if n, _ := result.RowsAffected(); n > 0 {
			slog.Info("expired sessions deleted", "count", n)
		}
		time.Sleep(time.Hour)
	}
}
