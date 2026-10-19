package postgres

import (
	"context"
	"log"
	"time"

	"weather-history/internal/domain"
)

// Updating the current row under its lock preserves a concurrent PUT.
func (s *Store) GetPreferences(ctx context.Context, id string) (domain.Preferences, error) {
	var preferences domain.Preferences
	err := s.pool.QueryRow(ctx, `INSERT INTO weather_preferences (session_id,preferences,expires_at)
 VALUES ($1,public.hstore('theme','light'),clock_timestamp()+$2::bigint*INTERVAL '1 second')
 ON CONFLICT (session_id) DO UPDATE SET
   preferences=CASE WHEN weather_preferences.expires_at<=clock_timestamp()
     THEN EXCLUDED.preferences ELSE weather_preferences.preferences END,
   expires_at=clock_timestamp()+$2::bigint*INTERVAL '1 second'
 RETURNING preferences OPERATOR(public.->) 'theme'`, id, int64(domain.SessionLifetime/time.Second)).Scan(&preferences.Theme)
	return preferences, err
}

func (s *Store) SetPreferences(ctx context.Context, id string, preferences domain.Preferences) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO weather_preferences (session_id,preferences,expires_at)
 VALUES ($1,public.hstore('theme',$2),clock_timestamp()+$3::bigint*INTERVAL '1 second')
 ON CONFLICT (session_id) DO UPDATE SET
   preferences=EXCLUDED.preferences,
   expires_at=clock_timestamp()+$3::bigint*INTERVAL '1 second'`, id, preferences.Theme, int64(domain.SessionLifetime/time.Second))
	return err
}

func (s *Store) prunePreferences(ctx context.Context) error {
	_, err := s.pool.Exec(ctx, "DELETE FROM weather_preferences WHERE expires_at<=NOW()")
	return err
}

func (s *Store) RunPreferencesCleanup(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cleanupCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := s.prunePreferences(cleanupCtx)
			cancel()
			if err != nil && ctx.Err() == nil {
				log.Print("Preferences cleanup: database unavailable")
			}
		}
	}
}
