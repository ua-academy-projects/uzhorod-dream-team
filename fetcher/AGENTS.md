# Agents instructions for Fetcher Service

## Component description
Fetcher Service is a backend component of the air quality tracking web app written in Go. It should expose a REST API service which acts as a proxy for OpenAQ API.

## Tools
- Build Tools: Make, Go CLI.
- Testing: Go Test CLI.

## Libraries
- STD (always a priority).
- Routing & Middleware: Chi.

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

## References
- OpenAQ API Reference: https://docs.openaq.org/api
