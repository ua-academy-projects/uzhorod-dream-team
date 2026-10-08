import { useEffect, useRef } from 'react';
import { MapContainer, TileLayer, Marker, Popup, useMap } from 'react-leaflet';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import type { Location } from '../types/api';

// Fix leaflet default icon issue with bundlers
import icon from 'leaflet/dist/images/marker-icon.png';
import iconShadow from 'leaflet/dist/images/marker-shadow.png';

const DefaultIcon = L.icon({
  iconUrl: icon,
  shadowUrl: iconShadow,
  iconSize: [25, 41],
  iconAnchor: [12, 41]
});

L.Marker.prototype.options.icon = DefaultIcon;

const KYIV_CENTER: [number, number] = [50.4501, 30.5234];

interface MapPaneProps {
  locations: Location[];
  selectedLocationId: number | null;
  onSelectLocation: (id: number) => void;
}

function RecenterAutomatically({ lat, lon }: { lat: number; lon: number }) {
  const map = useMap();
  useEffect(() => {
    map.setView([lat, lon], map.getZoom(), {
      animate: true
    });
  }, [lat, lon, map]);
  return null;
}

function LocationMarker({ location, selected, onSelect }: {
  location: Location;
  selected: boolean;
  onSelect: (id: number) => void;
}) {
  const marker = useRef<L.Marker>(null);

  useEffect(() => {
    if (selected) {
      marker.current?.openPopup();
    } else {
      marker.current?.closePopup();
    }
  }, [selected]);

  return (
    <Marker
      ref={marker}
      position={[location.lat, location.lon]}
      eventHandlers={{ click: () => onSelect(location.id) }}
    >
      <Popup>
        <div className="font-semibold text-sm">{location.name}</div>
      </Popup>
    </Marker>
  );
}

export function MapPane({ locations, selectedLocationId, onSelectLocation }: MapPaneProps) {
  const selectedLoc = locations.find((l) => l.id === selectedLocationId);

  return (
    <div className="w-full h-full relative z-0">
      <MapContainer 
        center={KYIV_CENTER} 
        zoom={11} 
        scrollWheelZoom={true} 
        className="w-full h-full"
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        {locations.map((loc) => (
          <LocationMarker
            key={loc.id}
            location={loc}
            selected={loc.id === selectedLocationId}
            onSelect={onSelectLocation}
          />
        ))}
        {selectedLoc && <RecenterAutomatically lat={selectedLoc.lat} lon={selectedLoc.lon} />}
      </MapContainer>
    </div>
  );
}
