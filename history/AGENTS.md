# Agents instructions for History Service

## Component description
Fetcher Service is a backend component of the air quality tracking web app written in Go. It should expose a REST API for the UI to draw plots. It also should have a regular scheduled procedure to fetch data using the Fetcher Service.

## Tools
- Build Tools: Make, Go CLI.
- Testing: Go Test CLI.
- Migrations: Goose.

## Libraries
- STD (always a priority).
- Routing & Middleware: Chi.
- PostgreSQL: pgx.

## Build commands
To build the project:
```bash
make build
```

To run the project:
```bash
make run
```

To clean the build output:
```bash
make clean
```

