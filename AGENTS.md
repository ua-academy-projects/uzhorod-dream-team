# Agents instructions

## Project Description
A simple web application that tracks real-time air quality data in the city of Kyiv using OpenAQ API and presents the information in the form of air quality dynamics plots grouped by location of observations.

## Project Structure
- fetcher/ - Fetcher Service written in Go. It's purpose is to present a REST API for the History Service to fetch recent measurements in the area using OpenAQ API.
- history/ - History Service written in Go. It's purpose is to query the Fetcher Service on a schedule and update its PostgreSQL database with new measurements. It also presents the UI component with a REST API to query available locations in Kyiv and their latest measurements by some preset timespans.
- ui/ - UI of the application, written in Typescript (Vite, React.js, TailwindCSS). It presents a map of available locations in Kyiv to choose from and an interactive plot where you can choose an air quality parameter for which to display the history of change.

## Go Code Conventions
- Comments: DO NOT WRITE comments unless instructed otherwise.
- Directory Structure: Maintain a conventional project structure with directories like cmd/, internal/, db/, api/ etc.
- Package Structure: Domain-driven. Group logic by resources rather than the layers. For example: package for dealing with locations should be named "locations" and a new location is created by "locations.New()"
- Architecture: Three-layered architecture. Presentation Layer (handlers), Business Layer (services), Data Access Layer (repositories).
- Testability: All code should be highly testable. Encapsulate dependencies in structs, use interfaces, make mocking easy.
- Configs: Application config definitions and initialization should be centralized. App config may be split into different structs if it has too much fields that can be split into proper groups. Provide default values for all fields where applicable and reasonable.
