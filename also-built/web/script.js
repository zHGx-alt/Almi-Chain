// Mobile menu
const menuButton = document.querySelector('.menu-toggle');
const menu = document.querySelector('#menu');
menuButton.addEventListener('click', () => {
  const open = menu.classList.toggle('open');
  menuButton.setAttribute('aria-expanded', String(open));
});
menu.querySelectorAll('a').forEach(link => link.addEventListener('click', () => {
  menu.classList.remove('open');
  menuButton.setAttribute('aria-expanded', 'false');
}));

// Signature dishes slideshow
const slides = [...document.querySelectorAll('.slide')];
const current = document.querySelector('#current');
let active = 0;
function showSlide(index) {
  slides[active].hidden = true;
  slides[active].classList.remove('active');
  active = (index + slides.length) % slides.length;
  slides[active].hidden = false;
  slides[active].classList.add('active');
  current.textContent = String(active + 1).padStart(2, '0');
}
document.querySelector('#next').addEventListener('click', () => showSlide(active + 1));
document.querySelector('#prev').addEventListener('click', () => showSlide(active - 1));

// The restaurant's location (same as the map marker) and straight-line distance (haversine formula)
const RESTAURANT = { lat: 43.263, lon: -2.935 };
function distanceKm(lat1, lon1, lat2, lon2) {
  const rad = deg => deg * Math.PI / 180;
  const dLat = rad(lat2 - lat1);
  const dLon = rad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}
const geoButton = document.querySelector('#geo-button');
const geoStatus = document.querySelector('#geo-status');
geoButton.addEventListener('click', () => {
  if (!('geolocation' in navigator)) {
    geoStatus.textContent = 'Your browser does not support geolocation.';
    return;
  }
  geoStatus.textContent = 'Getting your location…';
  geoButton.disabled = true;
  navigator.geolocation.getCurrentPosition(({ coords }) => {
    const lat = coords.latitude.toFixed(5);
    const lon = coords.longitude.toFixed(5);
    const km = distanceKm(coords.latitude, coords.longitude, RESTAURANT.lat, RESTAURANT.lon);
    const distance = km < 1 ? `${Math.round(km * 1000)} m` : `${km.toFixed(1)} km`;
    geoStatus.innerHTML = `You are about <strong>${distance}</strong> from the restaurant (as the crow flies). <a href="https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&amp;route=${lat}%2C${lon}%3B${RESTAURANT.lat}%2C${RESTAURANT.lon}" target="_blank" rel="noopener">See the walking route on OpenStreetMap</a>.`;
    geoButton.disabled = false;
  }, () => {
    geoStatus.textContent = 'Could not get your location. Check the browser permissions.';
    geoButton.disabled = false;
  }, { enableHighAccuracy: false, timeout: 8000, maximumAge: 300000 });
});

// The OpenStreetMap embed weighs over 1 MB: it only loads on request (without JavaScript, the link opens OpenStreetMap)
const mapLoad = document.querySelector('#map-load');
mapLoad.addEventListener('click', event => {
  event.preventDefault();
  const map = document.createElement('iframe');
  map.title = 'Map of the area of Bilbao where Almi Chain is';
  map.src = mapLoad.dataset.src;
  map.referrerPolicy = 'no-referrer-when-downgrade';
  mapLoad.replaceWith(map);
  map.focus();
});

document.querySelector('#contact-form').addEventListener('submit', event => {
  event.preventDefault();
  document.querySelector('#form-status').textContent = 'Demo: the form is ready, but it does not send any data.';
});
