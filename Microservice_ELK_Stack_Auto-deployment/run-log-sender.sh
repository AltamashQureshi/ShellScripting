#!/bin/bash
set -e

# Script: Log Sender (Logstash Forwarder)
# Purpose: Forward logs from file to remote ELK server
# Author: DevOps Team
# Version: 2.0.0

# ==============================================================================
# CONFIGURATION
# ==============================================================================

# REQUIRED: Set your ELK server IP address
ELK_SERVER_IP="${ELK_SERVER_IP:-}"

# Log file location
LOG_FILE="${LOG_FILE:-$(pwd)/logs/app.log}"

# Logstash image
LS_IMAGE="docker.elastic.co/logstash/logstash:8.12.0"

# Container name
CONTAINER_NAME="log-sender"

# Working directory
WORK_DIR="$(pwd)/sender"

# ==============================================================================
# FUNCTIONS
# ==============================================================================

log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_warn() {
    echo "[WARN] $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi
    
    # Check if ELK_SERVER_IP is set
    if [ -z "$ELK_SERVER_IP" ]; then
        log_error "ELK_SERVER_IP environment variable is not set"
        echo ""
        echo "Usage:"
        echo "  export ELK_SERVER_IP=192.168.1.100"
        echo "  $0"
        echo ""
        echo "Or:"
        echo "  ELK_SERVER_IP=192.168.1.100 $0"
        exit 1
    fi
    
    # Validate IP address format
    if ! [[ $ELK_SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Invalid IP address format: $ELK_SERVER_IP"
        exit 1
    fi
    
    # Check if log file exists
    if [ ! -f "$LOG_FILE" ]; then
        log_warn "Log file does not exist: $LOG_FILE"
        log_info "Creating empty log file..."
        mkdir -p "$(dirname "$LOG_FILE")"
        touch "$LOG_FILE"
    fi
}

test_elk_connectivity() {
    log_info "Testing connectivity to ELK server at ${ELK_SERVER_IP}:5044..."
    
    # Test if port 5044 is reachable (timeout 5 seconds)
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${ELK_SERVER_IP}/5044" 2>/dev/null; then
        log_info "✓ Successfully connected to ${ELK_SERVER_IP}:5044"
    else
        log_warn "⚠ Cannot connect to ${ELK_SERVER_IP}:5044"
        log_warn "Please ensure:"
        log_warn "  1. ELK server is running"
        log_warn "  2. Port 5044 is open"
        log_warn "  3. Firewall allows the connection"
        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted by user"
            exit 0
        fi
    fi
}

create_directories() {
    log_info "Creating directory structure..."
    mkdir -p ${WORK_DIR}
}

create_logstash_config() {
    log_info "Creating Logstash configuration..."
    
    cat << EOF > ${WORK_DIR}/logstash-sender.conf
# Input: Read from log file
input {
  file {
    path => "${LOG_FILE}"
    start_position => "beginning"
    sincedb_path => "/tmp/logstash_sincedb"
    codec => json
    type => "application-log"
    
    # File monitoring settings
    stat_interval => 1
    discover_interval => 5
    
    # Tag for tracking
    tags => ["forwarded", "file-input"]
  }
}

# Filter: Enrich logs before sending
filter {
  # Add forwarder metadata
  mutate {
    add_field => {
      "forwarder" => "logstash-sender"
      "forwarded_at" => "%{@timestamp}"
      "source_file" => "${LOG_FILE}"
      "elk_server" => "${ELK_SERVER_IP}"
    }
  }
  
  # Parse additional fields if needed
  if [level] == "ERROR" or [level] == "FATAL" {
    mutate {
      add_tag => ["error"]
    }
  }
}

# Output: Send to remote ELK server
output {
  tcp {
    host => "${ELK_SERVER_IP}"
    port => 5044
    codec => json_lines
    
    # Reconnection settings
    reconnect_interval => 10
  }
  
  # Debug output (comment out in production)
  stdout {
    codec => rubydebug {
      metadata => true
    }
  }
}
EOF

    log_info "Configuration created at: ${WORK_DIR}/logstash-sender.conf"
}

create_logstash_settings() {
    log_info "Creating Logstash settings..."
    
    cat << 'EOF' > ${WORK_DIR}/logstash.yml
# Logstash settings
http.host: "0.0.0.0"
http.port: 9600

# Pipeline settings
pipeline.workers: 1
pipeline.batch.size: 125
pipeline.batch.delay: 50

# Monitoring
xpack.monitoring.enabled: false

# Logging
log.level: info
EOF
}

create_pipelines_config() {
    log_info "Creating pipelines configuration..."
    
    cat << 'EOF' > ${WORK_DIR}/pipelines.yml
- pipeline.id: sender
  path.config: "/usr/share/logstash/pipeline/logstash-sender.conf"
  pipeline.workers: 1
EOF
}

cleanup_existing() {
    log_info "Cleaning up existing container..."
    docker rm -f ${CONTAINER_NAME} 2>/dev/null || true
    sleep 2
}

start_container() {
    log_info "Starting log sender container..."
    
    # Get absolute path for log file
    LOG_FILE_ABS=$(readlink -f "$LOG_FILE")
    LOG_FILE_DIR=$(dirname "$LOG_FILE_ABS")
    
    docker run -d \
      --name ${CONTAINER_NAME} \
      -v ${LOG_FILE_ABS}:${LOG_FILE}:ro \
      -v ${WORK_DIR}/logstash-sender.conf:/usr/share/logstash/pipeline/logstash-sender.conf:ro \
      -v ${WORK_DIR}/logstash.yml:/usr/share/logstash/config/logstash.yml:ro \
      -v ${WORK_DIR}/pipelines.yml:/usr/share/logstash/config/pipelines.yml:ro \
      -e LS_JAVA_OPTS="-Xms256m -Xmx512m" \
      -p 9600:9600 \
      --restart unless-stopped \
      ${LS_IMAGE}
    
    log_info "Waiting for container to start..."
    sleep 5
    
    # Check if container is running
    if docker ps | grep -q ${CONTAINER_NAME}; then
        log_info "✓ Container started successfully"
    else
        log_error "✗ Container failed to start"
        log_error "Checking logs..."
        docker logs ${CONTAINER_NAME}
        exit 1
    fi
}

verify_operation() {
    log_info "Verifying log forwarding operation..."
    
    sleep 5
    
    # Check container logs for errors
    if docker logs ${CONTAINER_NAME} 2>&1 | grep -i "error" | grep -v "ERROR" > /dev/null; then
        log_warn "⚠ Errors detected in container logs:"
        docker logs ${CONTAINER_NAME} 2>&1 | grep -i "error" | tail -5
    else
        log_info "✓ No errors detected"
    fi
    
    # Check if file is being read
    if docker logs ${CONTAINER_NAME} 2>&1 | grep -q "pipeline.*running"; then
        log_info "✓ Pipeline is running"
    else
        log_warn "⚠ Pipeline status unclear"
    fi
}

display_info() {
    echo ""
    echo "════════════════════════════════════════"
    echo "✅ Log Sender Deployment Complete!"
    echo "════════════════════════════════════════"
    echo ""
    echo "🔗 Configuration:"
    echo "   - Source file:    ${LOG_FILE}"
    echo "   - ELK server:     ${ELK_SERVER_IP}:5044"
    echo "   - Container:      ${CONTAINER_NAME}"
    echo "   - Config dir:     ${WORK_DIR}"
    echo ""
    echo "🔍 Management Commands:"
    echo "   - View logs:      docker logs -f ${CONTAINER_NAME}"
    echo "   - Check status:   docker ps | grep ${CONTAINER_NAME}"
    echo "   - API status:     curl http://localhost:9600/_node/stats/pipelines?pretty"
    echo "   - Stop:           docker stop ${CONTAINER_NAME}"
    echo "   - Start:          docker start ${CONTAINER_NAME}"
    echo "   - Remove:         docker rm -f ${CONTAINER_NAME}"
    echo ""
    echo "📊 Monitoring:"
    echo "   - Container stats: docker stats ${CONTAINER_NAME}"
    echo "   - Pipeline stats:  curl -s http://localhost:9600/_node/stats/pipelines | jq"
    echo ""
    echo "🔧 Troubleshooting:"
    echo "   - If logs aren't forwarding:"
    echo "     1. Check ELK server is accessible: nc -zv ${ELK_SERVER_IP} 5044"
    echo "     2. Verify log file has content: wc -l ${LOG_FILE}"
    echo "     3. Check container logs: docker logs ${CONTAINER_NAME}"
    echo "     4. Restart container: docker restart ${CONTAINER_NAME}"
    echo ""
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
    log_info "Starting Log Sender deployment..."
    
    check_prerequisites
    test_elk_connectivity
    create_directories
    create_logstash_config
    create_logstash_settings
    create_pipelines_config
    cleanup_existing
    start_container
    verify_operation
    display_info
}

# Run main function
main
