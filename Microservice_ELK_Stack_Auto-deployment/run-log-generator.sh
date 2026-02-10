#!/bin/bash
set -e

# Script: Log Generator Application Builder
# Purpose: Create and run a Java-based log generator with file output
# Author: DevOps Team
# Version: 3.0.0 - All fixes applied

# ==============================================================================
# CONFIGURATION
# ==============================================================================

APP_NAME="log-generator"
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
IMAGE_NAME="${APP_NAME}:${VERSION}"

# ==============================================================================
# FUNCTIONS
# ==============================================================================

log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi
}

create_project_structure() {
    log_info "Creating project structure..."
    
    mkdir -p ${APP_NAME}/src/main/java/com/example
    
    # FIXED: Create logs directory with proper permissions
    mkdir -p ${LOG_DIR}
    chmod 777 ${LOG_DIR}
    
    cd ${APP_NAME}
}

create_log_generator() {
    log_info "Creating Java log generator application..."
    
    cat << 'EOF' > src/main/java/com/example/LogGenerator.java
package com.example;

import java.io.FileWriter;
import java.io.PrintWriter;
import java.io.IOException;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Random;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Log Generator - Produces structured JSON logs for testing log aggregation systems
 */
public class LogGenerator {

    private static final Random random = new Random();
    private static final AtomicLong counter = new AtomicLong(0);
    
    // Configuration from environment
    private static final String SERVICE_NAME = 
            System.getenv().getOrDefault("SERVICE_NAME", "log-generator-service");
    private static final String APP_ENV = 
            System.getenv().getOrDefault("APP_ENV", "dev");
    private static final String LOG_FILE = 
            System.getenv().getOrDefault("LOG_FILE", "/var/log/app/app.log");
    private static final String VERSION = 
            System.getenv().getOrDefault("APP_VERSION", "1.0.0");
    private static final int LOG_INTERVAL_MS = 
            Integer.parseInt(System.getenv().getOrDefault("LOG_INTERVAL_MS", "1000"));
    
    // User actions for realistic logs
    private static final String[] ACTIONS = {
        "user.login", "user.logout", "page.view", "api.call", 
        "database.query", "cache.hit", "cache.miss", "file.upload",
        "payment.process", "email.send", "report.generate", "data.export"
    };
    
    // Error types
    private static final String[] ERROR_TYPES = {
        "DatabaseConnectionTimeout", "NullPointerException", "ServiceUnavailable",
        "AuthenticationFailure", "RateLimitExceeded", "ValidationError"
    };

    public static void main(String[] args) {
        log_info("Starting Log Generator");
        log_info("Service: " + SERVICE_NAME);
        log_info("Environment: " + APP_ENV);
        log_info("Output: " + LOG_FILE);
        log_info("Interval: " + LOG_INTERVAL_MS + "ms");
        
        // Graceful shutdown hook
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            log_info("Shutting down gracefully...");
            log_info("Total logs generated: " + counter.get());
        }));
        
        try {
            generateLogs();
        } catch (Exception e) {
            log_error("Fatal error in log generator: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }

    private static void generateLogs() throws Exception {
        while (!Thread.currentThread().isInterrupted()) {
            String requestId = UUID.randomUUID().toString();
            String action = ACTIONS[random.nextInt(ACTIONS.length)];
            long latency = random.nextInt(900) + 100;
            String userId = "user_" + random.nextInt(1000);
            
            // Determine log type based on weighted probability
            int logType = random.nextInt(100);
            
            if (logType < 70) {
                // 70% INFO logs
                writeLog("INFO", 
                        "Request processed successfully",
                        requestId,
                        action,
                        userId,
                        latency,
                        null,
                        null);
            } else if (logType < 90) {
                // 20% WARN logs
                String warning = latency > 800 ? "High latency detected" : "Resource threshold approaching";
                writeLog("WARN",
                        warning,
                        requestId,
                        action,
                        userId,
                        latency,
                        "threshold=" + (latency > 800 ? "800ms" : "75%"),
                        null);
            } else if (logType < 98) {
                // 8% ERROR logs
                String errorType = ERROR_TYPES[random.nextInt(ERROR_TYPES.length)];
                writeLog("ERROR",
                        "Error occurred during request processing",
                        requestId,
                        action,
                        userId,
                        null,
                        null,
                        errorType);
            } else {
                // 2% FATAL logs
                writeLog("FATAL",
                        "Critical system failure",
                        requestId,
                        action,
                        userId,
                        null,
                        null,
                        "SystemOutOfMemory");
            }
            
            counter.incrementAndGet();
            
            // Log progress every 100 entries
            if (counter.get() % 100 == 0) {
                log_info("Generated " + counter.get() + " log entries");
            }
            
            Thread.sleep(LOG_INTERVAL_MS);
        }
    }

    private static void writeLog(String level, String message, String requestId,
                                 String action, String userId, Long latency, 
                                 String metadata, String errorType) throws IOException {
        
        String timestamp = ZonedDateTime.now().format(DateTimeFormatter.ISO_INSTANT);
        
        StringBuilder logBuilder = new StringBuilder();
        logBuilder.append("{");
        logBuilder.append("\"timestamp\":\"").append(timestamp).append("\",");
        logBuilder.append("\"level\":\"").append(level).append("\",");
        logBuilder.append("\"service\":\"").append(SERVICE_NAME).append("\",");
        logBuilder.append("\"version\":\"").append(VERSION).append("\",");
        logBuilder.append("\"env\":\"").append(APP_ENV).append("\",");
        logBuilder.append("\"requestId\":\"").append(requestId).append("\",");
        logBuilder.append("\"action\":\"").append(action).append("\",");
        logBuilder.append("\"userId\":\"").append(userId).append("\",");
        logBuilder.append("\"message\":\"").append(message).append("\"");
        
        if (latency != null) {
            logBuilder.append(",\"latency_ms\":").append(latency);
        }
        
        if (metadata != null) {
            logBuilder.append(",\"metadata\":\"").append(metadata).append("\"");
        }
        
        if (errorType != null) {
            logBuilder.append(",\"errorType\":\"").append(errorType).append("\"");
            logBuilder.append(",\"stackTrace\":\"").append(generateStackTrace()).append("\"");
        }
        
        logBuilder.append(",\"host\":\"").append(getHostname()).append("\"");
        logBuilder.append("}");
        
        String log = logBuilder.toString();
        
        // Write to file
        try (PrintWriter out = new PrintWriter(new FileWriter(LOG_FILE, true))) {
            out.println(log);
        }
        
        // Also print to stdout for Docker logs
        System.out.println(log);
    }
    
    private static String generateStackTrace() {
        return "at com.example.Service.process(Service.java:" + random.nextInt(200) + ")";
    }
    
    private static String getHostname() {
        try {
            return java.net.InetAddress.getLocalHost().getHostName();
        } catch (Exception e) {
            return "unknown";
        }
    }
    
    private static void log_info(String message) {
        System.out.println("[LOG-GENERATOR] " + message);
    }
    
    private static void log_error(String message) {
        System.err.println("[LOG-GENERATOR] ERROR: " + message);
    }
}
EOF
}

create_pom() {
    log_info "Creating Maven POM file..."
    
    cat << EOF > pom.xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 
         http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <groupId>com.example</groupId>
  <artifactId>${APP_NAME}</artifactId>
  <version>${VERSION}</version>
  <packaging>jar</packaging>

  <name>Log Generator</name>
  <description>Generates structured JSON logs for testing</description>

  <properties>
    <maven.compiler.source>17</maven.compiler.source>
    <maven.compiler.target>17</maven.compiler.target>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>

  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>3.11.0</version>
        <configuration>
          <source>17</source>
          <target>17</target>
        </configuration>
      </plugin>
      
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-jar-plugin</artifactId>
        <version>3.3.0</version>
        <configuration>
          <archive>
            <manifest>
              <mainClass>com.example.LogGenerator</mainClass>
              <addDefaultImplementationEntries>true</addDefaultImplementationEntries>
            </manifest>
          </archive>
        </configuration>
      </plugin>
    </plugins>
  </build>
</project>
EOF
}

create_dockerfile() {
    log_info "Creating Dockerfile..."
    
    cat << EOF > Dockerfile
# Multi-stage build for smaller image size
FROM maven:3.9.6-eclipse-temurin-17-alpine AS build

WORKDIR /app

# Copy POM and download dependencies (cached layer)
COPY pom.xml .
RUN mvn dependency:go-offline -B

# Copy source and build
COPY src ./src
RUN mvn clean package -DskipTests

# Runtime stage
FROM eclipse-temurin:17-jre-alpine

# Install curl for health checks
RUN apk add --no-cache curl

WORKDIR /app

# FIXED: Create log directory with proper permissions for appuser
RUN mkdir -p /var/log/app && \
    chmod 755 /var/log/app

# Copy JAR from build stage
COPY --from=build /app/target/${APP_NAME}-${VERSION}.jar app.jar

# Environment variables with defaults
ENV SERVICE_NAME=log-generator-service \
    APP_ENV=production \
    APP_VERSION=${VERSION} \
    LOG_FILE=/var/log/app/app.log \
    LOG_INTERVAL_MS=1000 \
    JAVA_OPTS="-Xms128m -Xmx256m"

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD test -f \${LOG_FILE} && test \$(find \${LOG_FILE} -mmin -1 | wc -l) -gt 0 || exit 1

# FIXED: Create user and set ownership AFTER creating directories
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser && \
    chown -R appuser:appuser /app /var/log/app

USER appuser

# Start application
CMD ["sh", "-c", "java \${JAVA_OPTS} -jar app.jar"]
EOF
}

create_dockerignore() {
    log_info "Creating .dockerignore..."
    
    cat << 'EOF' > .dockerignore
target/
logs/
*.log
.git/
.gitignore
README.md
.DS_Store
EOF
}

build_image() {
    log_info "Building Docker image: ${IMAGE_NAME}"
    
    docker build -t ${IMAGE_NAME} -t ${APP_NAME}:latest .
    
    if [ $? -eq 0 ]; then
        log_info "Image built successfully!"
        docker images | grep ${APP_NAME}
    else
        log_error "Image build failed"
        exit 1
    fi
}

cleanup_container() {
    log_info "Cleaning up existing container..."
    docker rm -f ${APP_NAME} 2>/dev/null || true
    sleep 2
}

run_container() {
    log_info "Starting container with volume mount..."
    
    # FIXED: Ensure log directory exists with proper permissions
    if [ ! -d "${LOG_DIR}" ]; then
        mkdir -p "${LOG_DIR}"
    fi
    chmod 777 "${LOG_DIR}"
    
    docker run -d \
      --name ${APP_NAME} \
      -e APP_ENV=production \
      -e SERVICE_NAME=${APP_NAME} \
      -e LOG_INTERVAL_MS=1000 \
      -v "${LOG_DIR}:/var/log/app" \
      --restart unless-stopped \
      ${IMAGE_NAME}
    
    # Wait for container to start
    sleep 3
    
    # Check if container is running
    if docker ps | grep -q ${APP_NAME}; then
        log_info "Container started successfully!"
    else
        log_error "Container failed to start. Checking logs..."
        docker logs ${APP_NAME}
        exit 1
    fi
}

display_info() {
    echo ""
    echo "════════════════════════════════════════"
    echo "✅ Log Generator Deployment Complete!"
    echo "════════════════════════════════════════"
    echo ""
    echo "📦 Container: ${APP_NAME}"
    echo "🏷️  Image:     ${IMAGE_NAME}"
    echo "📁 Logs:      ${LOG_DIR}/app.log"
    echo ""
    echo "ℹ️  NOTE: If you have Filebeat running (from run-elk-remote.sh),"
    echo "   logs will be automatically forwarded to Logstash → Elasticsearch"
    echo ""
    echo "🔍 Management Commands:"
    echo "   - View logs:    tail -f ${LOG_DIR}/app.log"
    echo "   - Docker logs:  docker logs -f ${APP_NAME}"
    echo "   - Stop:         docker stop ${APP_NAME}"
    echo "   - Start:        docker start ${APP_NAME}"
    echo "   - Remove:       docker rm -f ${APP_NAME}"
    echo "   - Stats:        docker stats ${APP_NAME}"
    echo ""
    echo "📊 Log Statistics:"
    echo "   - Total entries: \$(wc -l < ${LOG_DIR}/app.log 2>/dev/null || echo 0)"
    echo "   - File size:     \$(du -h ${LOG_DIR}/app.log 2>/dev/null || echo 'N/A')"
    echo ""
    echo "🔄 Watch live logs:"
    echo "   tail -f ${LOG_DIR}/app.log | jq ."
    echo ""
    echo "💡 Tip: If container keeps restarting, check permissions:"
    echo "   chmod 777 ${LOG_DIR}"
    echo "   docker logs ${APP_NAME}"
    echo ""
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
    log_info "Starting Log Generator deployment..."
    
    check_prerequisites
    create_project_structure
    create_log_generator
    create_pom
    create_dockerfile
    create_dockerignore
    build_image
    
    cd ..
    
    cleanup_container
    run_container
    display_info
}

# Run main function
main
