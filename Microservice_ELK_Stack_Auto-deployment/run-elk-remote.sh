#!/bin/bash
set -e

# Script: ELK Stack Setup for Remote Log Collection
# Purpose: Deploy Elasticsearch, Logstash, Kibana, Heartbeat, and Filebeat with Docker
# Author: DevOps Team
# Version: 3.0.0 - All fixes applied

# ==============================================================================
# CONFIGURATION
# ==============================================================================

NETWORK="elk-net"
BASE_DIR="/opt/elk"
ES_IMAGE="docker.elastic.co/elasticsearch/elasticsearch:8.12.0"
LS_IMAGE="docker.elastic.co/logstash/logstash:8.12.0"
KB_IMAGE="docker.elastic.co/kibana/kibana:8.12.0"
HB_IMAGE="docker.elastic.co/beats/heartbeat:8.12.0"
FB_IMAGE="docker.elastic.co/beats/filebeat:8.12.0"

# Resource limits (adjust based on your system)
ES_MEMORY="1g"
LS_MEMORY="512m"

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
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running. Please start Docker."
        exit 1
    fi
    
    # Check available memory
    available_mem=$(free -g 2>/dev/null | awk '/^Mem:/{print $7}' || echo "4")
    if [ "$available_mem" -lt 2 ]; then
        log_error "Insufficient memory. At least 2GB free memory required."
        exit 1
    fi
}

create_directories() {
    log_info "Creating directory structure..."
    mkdir -p ${BASE_DIR}/{logstash,heartbeat,filebeat,elasticsearch}
    chmod -R 755 ${BASE_DIR}
    
    # Create logs directory for log generator
    mkdir -p $(pwd)/logs
    chmod 777 $(pwd)/logs
}

setup_network() {
    log_info "Setting up Docker network: ${NETWORK}"
    if ! docker network inspect ${NETWORK} &>/dev/null; then
        docker network create ${NETWORK}
        log_info "Network ${NETWORK} created"
    else
        log_info "Network ${NETWORK} already exists"
    fi
}

configure_logstash() {
    log_info "Configuring Logstash pipeline for remote log collection..."
    
    cat << 'EOF' > ${BASE_DIR}/logstash/logstash.conf
input {
  tcp {
    port => 5044
    codec => json_lines
    type => "tcp-json"
  }
  
  # Fallback for plain text logs
  tcp {
    port => 5045
    codec => line
    type => "tcp-plain"
  }
}

filter {
  # Parse timestamp if present
  if [timestamp] {
    date {
      match => ["timestamp", "ISO8601", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"]
      target => "@timestamp"
      remove_field => ["timestamp"]
    }
  }
  
  # Add metadata
  mutate {
    add_field => {
      "[@metadata][index_prefix]" => "remote-app-logs"
    }
  }
  
  # Enrich with geo data if IP is present
  if [client_ip] {
    geoip {
      source => "client_ip"
      target => "geoip"
    }
  }
}

output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    index => "%{[@metadata][index_prefix]}-%{+YYYY.MM.dd}"
    ilm_enabled => false
  }
  
  # Debugging output (comment out in production)
  stdout {
    codec => rubydebug
  }
}
EOF

    # Create Logstash settings
    cat << 'EOF' > ${BASE_DIR}/logstash/logstash.yml
http.host: "0.0.0.0"
xpack.monitoring.enabled: true
xpack.monitoring.elasticsearch.hosts: ["http://elasticsearch:9200"]
pipeline.workers: 2
pipeline.batch.size: 125
pipeline.batch.delay: 50
EOF
}

configure_heartbeat() {
    log_info "Configuring Heartbeat monitoring..."
    
    # FIXED: Simplified config with proper template settings
    cat << 'EOF' > ${BASE_DIR}/heartbeat/heartbeat.yml
heartbeat.monitors:
- type: http
  id: elasticsearch
  name: Elasticsearch Health
  schedule: '@every 30s'
  urls:
    - http://elasticsearch:9200
  check.response.status: [200, 201]

- type: http
  id: kibana
  name: Kibana Health
  schedule: '@every 30s'
  urls:
    - http://kibana:5601/api/status
  check.response.status: [200]

- type: tcp
  id: logstash
  name: Logstash TCP Port
  schedule: '@every 30s'
  hosts: ["logstash:5044"]

output.elasticsearch:
  hosts: ["http://elasticsearch:9200"]
  # FIXED: Use default index pattern
  # index: "heartbeat-%{+yyyy.MM.dd}"  # Removed - causes template error

# FIXED: Disable file logging to avoid permission issues
logging.to_files: false
logging.to_stderr: true
logging.level: info

setup.kibana:
  host: "http://kibana:5601"
EOF
}

configure_filebeat() {
    log_info "Configuring Filebeat for log collection..."
    
    cat << 'EOF' > ${BASE_DIR}/filebeat/filebeat.yml
filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - /var/log/app/app.log
    json.keys_under_root: true
    json.add_error_key: true
    close_inactive: 5m

output.logstash:
  hosts: ["logstash:5044"]

# FIXED: Disable file logging to avoid permission issues
logging.to_files: false
logging.to_stderr: true
logging.level: info
EOF
}

cleanup_existing() {
    log_info "Cleaning up existing containers..."
    docker rm -f elasticsearch logstash kibana heartbeat filebeat 2>/dev/null || true
    
    # Wait for containers to fully stop
    sleep 2
}

start_elasticsearch() {
    log_info "Starting Elasticsearch..."
    
    # FIXED: Use environment variables instead of config file to avoid YAML parsing issues
    docker run -d \
      --name elasticsearch \
      --network ${NETWORK} \
      -p 9200:9200 \
      -p 9300:9300 \
      -e discovery.type=single-node \
      -e xpack.security.enabled=false \
      -e xpack.security.enrollment.enabled=false \
      -e xpack.security.http.ssl.enabled=false \
      -e xpack.security.transport.ssl.enabled=false \
      -e "http.cors.enabled=true" \
      -e "http.cors.allow-origin=\"*\"" \
      -e "http.cors.allow-headers=X-Requested-With,Content-Type,Content-Length,Authorization" \
      -e ES_JAVA_OPTS="-Xms${ES_MEMORY} -Xmx${ES_MEMORY}" \
      -e cluster.name=elk-cluster \
      -e node.name=elk-node-01 \
      -e bootstrap.memory_lock=true \
      -v esdata:/usr/share/elasticsearch/data \
      --ulimit nofile=65535:65535 \
      --ulimit memlock=-1:-1 \
      --restart unless-stopped \
      ${ES_IMAGE}
    
    log_info "Waiting for Elasticsearch to become healthy..."
    
    # Wait for Elasticsearch to be ready (max 90 seconds)
    for i in {1..90}; do
        if curl -s http://localhost:9200/_cluster/health &>/dev/null; then
            log_info "Elasticsearch is ready!"
            break
        fi
        if [ $i -eq 90 ]; then
            log_error "Elasticsearch failed to start within 90 seconds"
            docker logs elasticsearch --tail 50
            exit 1
        fi
        sleep 1
    done
}

start_logstash() {
    log_info "Starting Logstash..."
    
    docker run -d \
      --name logstash \
      --network ${NETWORK} \
      -p 5044:5044 \
      -p 5045:5045 \
      -p 9600:9600 \
      -e LS_JAVA_OPTS="-Xms${LS_MEMORY} -Xmx${LS_MEMORY}" \
      -v ${BASE_DIR}/logstash/logstash.conf:/usr/share/logstash/pipeline/logstash.conf:ro \
      -v ${BASE_DIR}/logstash/logstash.yml:/usr/share/logstash/config/logstash.yml:ro \
      --restart unless-stopped \
      ${LS_IMAGE}
    
    log_info "Waiting for Logstash to start..."
    sleep 15
}

start_kibana() {
    log_info "Starting Kibana..."
    
    docker run -d \
      --name kibana \
      --network ${NETWORK} \
      -p 5601:5601 \
      -e ELASTICSEARCH_HOSTS=http://elasticsearch:9200 \
      -e SERVER_NAME=kibana \
      -e SERVER_HOST=0.0.0.0 \
      --restart unless-stopped \
      ${KB_IMAGE}
    
    log_info "Waiting for Kibana to become available..."
    
    # Wait for Kibana (max 120 seconds)
    for i in {1..120}; do
        if curl -s http://localhost:5601/api/status &>/dev/null; then
            log_info "Kibana is ready!"
            break
        fi
        if [ $i -eq 120 ]; then
            log_error "Kibana failed to start within 120 seconds"
            docker logs kibana --tail 50
            exit 1
        fi
        sleep 1
    done
}

start_heartbeat() {
    log_info "Starting Heartbeat..."
    
    # FIXED: Run as root to avoid permission issues, disable file logging
    docker run -d \
      --name heartbeat \
      --network ${NETWORK} \
      --user root \
      -v ${BASE_DIR}/heartbeat/heartbeat.yml:/usr/share/heartbeat/heartbeat.yml:ro \
      --restart unless-stopped \
      ${HB_IMAGE} \
      --strict.perms=false -e
    
    sleep 5
    
    # Verify Heartbeat started successfully
    if docker ps | grep -q heartbeat; then
        log_info "Heartbeat started successfully"
    else
        log_error "Heartbeat failed to start. Checking logs..."
        docker logs heartbeat
    fi
}

start_filebeat() {
    log_info "Starting Filebeat for log forwarding..."
    
    # Get absolute path to logs directory
    LOGS_DIR="$(pwd)/logs"
    
    # Create logs directory if it doesn't exist
    mkdir -p "$LOGS_DIR"
    chmod 777 "$LOGS_DIR"
    
    # FIXED: Run as root to avoid permission issues
    docker run -d \
      --name filebeat \
      --network ${NETWORK} \
      --user root \
      -v "${LOGS_DIR}:/var/log/app:ro" \
      -v ${BASE_DIR}/filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro \
      --restart unless-stopped \
      ${FB_IMAGE} \
      --strict.perms=false -e
    
    log_info "Filebeat started - will forward logs from ${LOGS_DIR}/app.log to Logstash"
}

display_info() {
    log_info "=================================="
    log_info "ELK Stack Deployment Complete!"
    log_info "=================================="
    echo ""
    echo "📊 Services:"
    echo "   - Elasticsearch: http://localhost:9200"
    echo "   - Kibana:        http://localhost:5601"
    echo "   - Logstash TCP:  localhost:5044 (JSON)"
    echo "   - Logstash TCP:  localhost:5045 (Plain)"
    echo ""
    echo "📁 Log Directory: $(pwd)/logs"
    echo "   - Place app.log here, Filebeat will forward to Logstash automatically"
    echo ""
    echo "🔍 Management Commands:"
    echo "   - View logs:     docker logs -f <container-name>"
    echo "   - Stop all:      docker stop elasticsearch logstash kibana heartbeat filebeat"
    echo "   - Start all:     docker start elasticsearch logstash kibana heartbeat filebeat"
    echo "   - Remove all:    docker rm -f elasticsearch logstash kibana heartbeat filebeat"
    echo ""
    echo "📈 Health Checks:"
    echo "   - Elasticsearch: curl http://localhost:9200/_cluster/health?pretty"
    echo "   - Check indices: curl http://localhost:9200/_cat/indices?v"
    echo "   - Doc count:     curl http://localhost:9200/remote-app-logs-*/_count?pretty"
    echo ""
    echo "🔧 Kibana Setup:"
    echo "   1. Open http://localhost:5601"
    echo "   2. Create Data View with pattern: remote-app-logs-*"
    echo "   3. Timestamp field: @timestamp"
    echo "   4. Go to Discover to view logs"
    echo ""
    echo "🔗 Network: ${NETWORK}"
    echo "📁 Config:  ${BASE_DIR}"
    echo ""
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
    log_info "Starting ELK Stack deployment (with Filebeat)..."
    
    check_prerequisites
    create_directories
    setup_network
    configure_logstash
    configure_heartbeat
    configure_filebeat
    cleanup_existing
    
    start_elasticsearch
    start_logstash
    start_kibana
    start_heartbeat
    start_filebeat
    
    display_info
}

# Run main function
main
