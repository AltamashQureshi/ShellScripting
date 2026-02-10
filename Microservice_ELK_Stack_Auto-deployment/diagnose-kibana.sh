#!/bin/bash

# Kibana Data View Diagnostic Script
# This script checks all components to help diagnose why data isn't visible in Kibana

echo "========================================"
echo "Kibana Data View Diagnostic Tool"
echo "========================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Step 1: Check Docker Containers
echo "Step 1: Checking Docker Containers..."
echo "-----------------------------------"

containers=("elasticsearch" "logstash" "kibana" "log-generator")
all_running=true

for container in "${containers[@]}"; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        status=$(docker inspect -f '{{.State.Status}}' $container)
        if [ "$status" = "running" ]; then
            check_pass "$container is running"
        else
            check_fail "$container status: $status"
            all_running=false
        fi
    else
        check_fail "$container is not running"
        all_running=false
    fi
done
echo ""

# Step 2: Check Log File
echo "Step 2: Checking Log File..."
echo "-----------------------------------"

if [ -f "logs/app.log" ]; then
    log_size=$(du -h logs/app.log | cut -f1)
    log_lines=$(wc -l < logs/app.log)
    check_pass "Log file exists: logs/app.log"
    check_pass "Size: $log_size, Lines: $log_lines"
    
    # Check if file is growing
    size1=$(stat -f%z logs/app.log 2>/dev/null || stat -c%s logs/app.log 2>/dev/null)
    sleep 3
    size2=$(stat -f%z logs/app.log 2>/dev/null || stat -c%s logs/app.log 2>/dev/null)
    
    if [ "$size2" -gt "$size1" ]; then
        check_pass "Log file is growing (active)"
    else
        check_warn "Log file is not growing (may be inactive)"
    fi
else
    check_fail "Log file not found: logs/app.log"
fi
echo ""

# Step 3: Check Elasticsearch
echo "Step 3: Checking Elasticsearch..."
echo "-----------------------------------"

if curl -s http://localhost:9200 > /dev/null 2>&1; then
    check_pass "Elasticsearch is accessible on port 9200"
    
    # Check cluster health
    health=$(curl -s http://localhost:9200/_cluster/health | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    if [ "$health" = "green" ] || [ "$health" = "yellow" ]; then
        check_pass "Cluster health: $health"
    else
        check_fail "Cluster health: $health"
    fi
    
    # Check indices
    echo ""
    echo "Indices in Elasticsearch:"
    curl -s "localhost:9200/_cat/indices?v" | grep -E "remote-app-logs|INDEX"
    echo ""
    
    # Check document count
    today=$(date +%Y.%m.%d)
    yesterday=$(date -d "yesterday" +%Y.%m.%d 2>/dev/null || date -v-1d +%Y.%m.%d 2>/dev/null)
    
    count_today=$(curl -s "localhost:9200/remote-app-logs-${today}/_count" 2>/dev/null | grep -o '"count":[0-9]*' | cut -d':' -f2)
    count_yesterday=$(curl -s "localhost:9200/remote-app-logs-${yesterday}/_count" 2>/dev/null | grep -o '"count":[0-9]*' | cut -d':' -f2)
    count_all=$(curl -s "localhost:9200/remote-app-logs-*/_count" 2>/dev/null | grep -o '"count":[0-9]*' | cut -d':' -f2)
    
    if [ ! -z "$count_all" ] && [ "$count_all" -gt 0 ]; then
        check_pass "Total documents in remote-app-logs-*: $count_all"
        if [ ! -z "$count_today" ] && [ "$count_today" -gt 0 ]; then
            check_pass "Documents today ($today): $count_today"
        else
            check_warn "No documents today, but found $count_all documents in older indices"
        fi
    else
        check_fail "No documents found in remote-app-logs-* indices"
        echo ""
        echo "This is the main issue! Logs are not reaching Elasticsearch."
    fi
else
    check_fail "Cannot connect to Elasticsearch on localhost:9200"
fi
echo ""

# Step 4: Check Logstash
echo "Step 4: Checking Logstash..."
echo "-----------------------------------"

if nc -zv localhost 5044 2>&1 | grep -q "succeeded\|open"; then
    check_pass "Logstash port 5044 is open"
else
    check_fail "Cannot connect to Logstash port 5044"
fi

if docker ps --format '{{.Names}}' | grep -q "^logstash$"; then
    if docker logs logstash 2>&1 | grep -q "Pipeline.*started\|Pipelines running"; then
        check_pass "Logstash pipeline is running"
    else
        check_warn "Logstash may not have started its pipeline yet"
    fi
    
    # Check for errors
    if docker logs logstash 2>&1 | tail -50 | grep -i "error\|exception\|failed" > /dev/null; then
        check_fail "Errors found in Logstash logs (see below)"
        echo ""
        echo "Recent Logstash errors:"
        docker logs logstash 2>&1 | tail -50 | grep -i "error\|exception\|failed"
    else
        check_pass "No errors in recent Logstash logs"
    fi
fi
echo ""

# Step 5: Check Kibana
echo "Step 5: Checking Kibana..."
echo "-----------------------------------"

if curl -s http://localhost:5601/api/status 2>&1 | grep -q "available\|green"; then
    check_pass "Kibana is accessible on port 5601"
    check_pass "Open Kibana at: http://localhost:5601"
else
    check_fail "Cannot connect to Kibana on localhost:5601"
fi
echo ""

# Step 6: Summary and Recommendations
echo "========================================"
echo "Summary and Recommendations"
echo "========================================"
echo ""

# Determine main issue
if [ "$all_running" = false ]; then
    echo "🔴 CRITICAL: Not all containers are running"
    echo ""
    echo "Action Required:"
    echo "1. Start missing containers:"
    echo "   docker start elasticsearch logstash kibana log-generator"
    echo ""
    echo "2. If containers keep stopping, check logs:"
    echo "   docker logs elasticsearch"
    echo "   docker logs logstash"
    echo ""
elif [ ! -f "logs/app.log" ]; then
    echo "🔴 CRITICAL: Log file not found"
    echo ""
    echo "Action Required:"
    echo "1. Ensure log generator is running:"
    echo "   ./run-log-generator.sh"
    echo ""
elif [ -z "$count_all" ] || [ "$count_all" -eq 0 ]; then
    echo "🔴 CRITICAL: No data in Elasticsearch"
    echo ""
    echo "This means logs are not flowing from Logstash to Elasticsearch."
    echo ""
    echo "Action Required:"
    echo "1. Test Logstash → Elasticsearch connection:"
    echo "   docker exec logstash curl -s http://elasticsearch:9200"
    echo ""
    echo "2. Check Logstash configuration:"
    echo "   docker exec logstash cat /usr/share/logstash/pipeline/logstash.conf"
    echo ""
    echo "3. Send a test message to Logstash:"
    echo "   echo '{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\",\"level\":\"TEST\",\"message\":\"Test\"}' | nc localhost 5044"
    echo "   sleep 5"
    echo "   curl -s \"localhost:9200/remote-app-logs-*/_search?q=level:TEST&pretty\""
    echo ""
elif [ -z "$count_today" ] || [ "$count_today" -eq 0 ]; then
    echo "🟡 WARNING: No data today, but old data exists"
    echo ""
    echo "You have $count_all total documents, but none from today."
    echo ""
    echo "Action Required in Kibana:"
    echo "1. Open Kibana: http://localhost:5601"
    echo "2. Go to Discover"
    echo "3. Change time range to 'Last 7 days' or 'Last 30 days'"
    echo "4. You should see your old data"
    echo ""
    echo "To generate new data:"
    echo "   docker restart log-generator"
    echo ""
else
    echo "🟢 SUCCESS: System appears to be working!"
    echo ""
    echo "Found $count_all total documents in Elasticsearch"
    echo "Including $count_today documents from today"
    echo ""
    echo "Next Steps in Kibana:"
    echo "1. Open Kibana: http://localhost:5601"
    echo "2. Go to Management → Stack Management → Data Views"
    echo "3. Create a Data View:"
    echo "   - Name: Remote App Logs"
    echo "   - Index pattern: remote-app-logs-*"
    echo "   - Timestamp field: @timestamp (or timestamp)"
    echo "4. Go to Analytics → Discover"
    echo "5. Select 'Remote App Logs' from the dropdown"
    echo "6. Adjust time range if needed (top right)"
    echo ""
fi

# Additional diagnostics
echo "========================================"
echo "Additional Information"
echo "========================================"
echo ""

echo "Sample document from Elasticsearch:"
curl -s "localhost:9200/remote-app-logs-*/_search?size=1&sort=@timestamp:desc&pretty" 2>/dev/null | grep -A 20 "_source" || echo "No documents found"

echo ""
echo "========================================"
echo "Diagnostic complete!"
echo ""
echo "For more help, see: KIBANA-TROUBLESHOOTING.md"
echo "========================================"
