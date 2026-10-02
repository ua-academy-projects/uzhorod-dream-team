package syncer

import (
	"context"
	"log"
	"time"

	"history/internal/config"
	"history/internal/locations"
	"history/internal/measurements"
	"history/internal/parameters"
)

type Syncer struct {
	cfg        *config.Config
	locRepo    locations.Repository
	paramRepo  parameters.Repository
	measRepo   measurements.Repository
	fetcher    FetcherClient
	paramCache map[string]int
}

func NewSyncer(cfg *config.Config, locRepo locations.Repository, paramRepo parameters.Repository, measRepo measurements.Repository, fetcher FetcherClient) *Syncer {
	return &Syncer{
		cfg:        cfg,
		locRepo:    locRepo,
		paramRepo:  paramRepo,
		measRepo:   measRepo,
		fetcher:    fetcher,
		paramCache: make(map[string]int),
	}
}

func (s *Syncer) Start(ctx context.Context) {
	log.Println("Starting backfill routine...")
	if err := s.runBackfill(ctx); err != nil {
		log.Printf("Backfill routine encountered an error: %v", err)
	} else {
		log.Println("Backfill routine completed successfully.")
	}

	ticker := time.NewTicker(s.cfg.SyncInterval)
	defer ticker.Stop()

	log.Printf("Starting scheduled polling every %s", s.cfg.SyncInterval)
	for {
		select {
		case <-ctx.Done():
			log.Println("Syncer stopped")
			return
		case <-ticker.C:
			if err := s.syncLatest(ctx); err != nil {
				log.Printf("Error during sync latest: %v", err)
			}
		}
	}
}

func (s *Syncer) runBackfill(ctx context.Context) error {
	locs, err := s.fetcher.GetLocations(ctx)
	if err != nil {
		return err
	}

	dbLocs, err := s.locRepo.GetAll(ctx)
	if err != nil {
		return err
	}

	dbLocMap := make(map[int]locations.Location)
	for _, dl := range dbLocs {
		dbLocMap[dl.ID] = dl
	}

	for _, fl := range locs {
		now := time.Now()
		loc := locations.Location{
			ID:           fl.ID,
			Name:         fl.Name,
			Lat:          fl.Lat,
			Lon:          fl.Lon,
			LastSyncTime: &now,
		}

		dl, exists := dbLocMap[fl.ID]
		var fetchFrom time.Time
		needsBackfill := false

		if !exists || dl.LastSyncTime == nil {
			fetchFrom = time.Now().Add(-s.cfg.DefaultBackfillDuration)
			log.Printf("New location %d, fetching data from %s ago", fl.ID, s.cfg.DefaultBackfillDuration)
			needsBackfill = true
		} else {
			age := time.Since(*dl.LastSyncTime)
			if age >= s.cfg.BackfillThreshold {
				fetchFrom = *dl.LastSyncTime
				needsBackfill = true
			} else {
				log.Printf("Location %d was synced recently (age: %s), skipping backfill", fl.ID, age)
			}
		}

		if needsBackfill {
			log.Printf("Backfilling loc %d from %s...", fl.ID, fetchFrom.Format(time.RFC3339))
			fromStr := fetchFrom.UTC().Format(time.RFC3339)
			meas, err := s.fetcher.GetLocationMeasurements(ctx, fl.ID, fromStr)
			if err != nil {
				log.Printf("Failed to fetch measurements for loc %d: %v", fl.ID, err)
				continue
			}

			if len(meas) > 0 {
				if err := s.saveMeasurements(ctx, fl.ID, meas); err != nil {
					log.Printf("Failed to save measurements for loc %d: %v", fl.ID, err)
					continue
				}
			}
		}

		if err := s.locRepo.Upsert(ctx, loc); err != nil {
			log.Printf("Failed to upsert loc %d: %v", fl.ID, err)
		}
	}

	return nil
}

func (s *Syncer) syncLatest(ctx context.Context) error {
	log.Println("Syncing latest data from Fetcher...")
	locs, err := s.fetcher.GetLocationsLatest(ctx)
	if err != nil {
		return err
	}

	for _, fl := range locs {
		now := time.Now()
		loc := locations.Location{
			ID:           fl.ID,
			Name:         fl.Name,
			Lat:          fl.Lat,
			Lon:          fl.Lon,
			LastSyncTime: &now,
		}

		if err := s.locRepo.Upsert(ctx, loc); err != nil {
			log.Printf("Failed to upsert location %d: %v", loc.ID, err)
			continue
		}

		if len(fl.Latest) > 0 {
			if err := s.saveMeasurements(ctx, loc.ID, fl.Latest); err != nil {
				log.Printf("Failed to save latest measurements for loc %d: %v", loc.ID, err)
			}
		}
	}

	log.Println("Sync complete.")
	return nil
}

func (s *Syncer) saveMeasurements(ctx context.Context, locID int, fms []FetcherMeasurement) error {
	var repoMeasurements []measurements.Measurement

	for _, fm := range fms {
		cacheKey := fm.Parameter + "|" + fm.Unit
		paramID, exists := s.paramCache[cacheKey]
		if !exists {
			id, err := s.paramRepo.GetOrCreate(ctx, fm.Parameter, fm.Unit)
			if err != nil {
				return err
			}
			paramID = id
			s.paramCache[cacheKey] = id
		}

		t, err := time.Parse(time.RFC3339, fm.Timestamp)
		if err != nil {
			log.Printf("Failed to parse timestamp '%s': %v", fm.Timestamp, err)
			continue
		}

		repoMeasurements = append(repoMeasurements, measurements.Measurement{
			LocationID:  locID,
			ParameterID: paramID,
			Value:       fm.Value,
			Timestamp:   t,
		})
	}

	return s.measRepo.InsertBatch(ctx, repoMeasurements)
}
