# Get the latest tag for Swift on Linux (non-slim one)
FROM swift:5.5

WORKDIR /package

# Get source and test code
COPY . ./

# Build package
RUN swift build

# Run all test on Linux machine
CMD ["swift", "test"]
