# Dockerfile
FROM swift:6.2-jammy

# Install dependencies
RUN apt-get update && apt-get install -y \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy package manifest
COPY Package.swift .

# Copy source files
COPY Sources ./Sources
COPY Tests ./Tests

# Resolve dependencies
RUN swift package resolve

# Build the project
RUN swift build

# Run tests by default
CMD ["swift", "test", "--parallel"]
