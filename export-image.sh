#!/bin/bash

# Docker Image Export and Compression Script
# This script exports Docker images to compressed tar.gz files

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS] IMAGE_NAME [OUTPUT_FILE]"
    echo ""
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -c, --compression LEVEL  Compression level 1-9 (default: 9)"
    echo "  -v, --verbose     Verbose output"
    echo ""
    echo "Arguments:"
    echo "  IMAGE_NAME        Docker image name (e.g., my-postgres-pgvector:slim)"
    echo "  OUTPUT_FILE       Output filename (optional, defaults to image-name.tar.gz)"
    echo ""
    echo "Examples:"
    echo "  $0 my-postgres-pgvector:slim"
    echo "  $0 my-postgres-pgvector:slim postgres-pgvector.tar.gz"
    echo "  $0 -c 6 my-postgres-pgvector:slim fast-compressed.tar.gz"
}

# Function to format bytes
format_bytes() {
    local bytes=$1
    if (( bytes > 1073741824 )); then
        echo "$(( bytes / 1073741824 ))GB"
    elif (( bytes > 1048576 )); then
        echo "$(( bytes / 1048576 ))MB"
    elif (( bytes > 1024 )); then
        echo "$(( bytes / 1024 ))KB"
    else
        echo "${bytes}B"
    fi
}

# Default values
COMPRESSION_LEVEL=9
VERBOSE=false
IMAGE_NAME=""
OUTPUT_FILE=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -c|--compression)
            COMPRESSION_LEVEL="$2"
            if [[ ! "$COMPRESSION_LEVEL" =~ ^[1-9]$ ]]; then
                print_error "Compression level must be between 1-9"
                exit 1
            fi
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -*)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            if [[ -z "$IMAGE_NAME" ]]; then
                IMAGE_NAME="$1"
            elif [[ -z "$OUTPUT_FILE" ]]; then
                OUTPUT_FILE="$1"
            else
                print_error "Too many arguments"
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate image name
if [[ -z "$IMAGE_NAME" ]]; then
    print_error "Image name is required"
    show_usage
    exit 1
fi

# Generate output filename if not provided
if [[ -z "$OUTPUT_FILE" ]]; then
    # Convert image name to safe filename
    OUTPUT_FILE=$(echo "$IMAGE_NAME" | sed 's/[^a-zA-Z0-9._-]/-/g').tar.gz
fi

# Main export process
main() {
    print_status "Starting Docker image export and compression..."
    print_status "Image: ${IMAGE_NAME}"
    print_status "Output: ${OUTPUT_FILE}"
    print_status "Compression Level: ${COMPRESSION_LEVEL}"
    
    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        print_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi
    
    # Check if image exists
    if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        print_error "Image '$IMAGE_NAME' not found."
        print_status "Available images:"
        docker images
        exit 1
    fi
    
    # Get image size
    IMAGE_SIZE=$(docker image inspect "$IMAGE_NAME" --format '{{.Size}}')
    print_status "Original image size: $(format_bytes $IMAGE_SIZE)"
    
    # Export and compress
    print_status "Exporting and compressing image..."
    EXPORT_START_TIME=$(date +%s)
    
    if [[ "$VERBOSE" == true ]]; then
        docker save "$IMAGE_NAME" | gzip -${COMPRESSION_LEVEL}v > "$OUTPUT_FILE"
    else
        docker save "$IMAGE_NAME" | gzip -${COMPRESSION_LEVEL} > "$OUTPUT_FILE"
    fi
    
    EXPORT_END_TIME=$(date +%s)
    EXPORT_DURATION=$((EXPORT_END_TIME - EXPORT_START_TIME))
    
    # Check if export was successful
    if [[ $? -eq 0 && -f "$OUTPUT_FILE" ]]; then
        COMPRESSED_SIZE=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE" 2>/dev/null)
        COMPRESSION_RATIO=$(( (IMAGE_SIZE - COMPRESSED_SIZE) * 100 / IMAGE_SIZE ))
        
        print_success "Export completed successfully in ${EXPORT_DURATION} seconds!"
        print_status "Compressed file: ${OUTPUT_FILE}"
        print_status "Compressed size: $(format_bytes $COMPRESSED_SIZE)"
        print_status "Compression ratio: ${COMPRESSION_RATIO}%"
        
        # Check if under 100MB
        if (( COMPRESSED_SIZE <= 104857600 )); then  # 100MB = 104857600 bytes
            print_success "✅ Compressed image is under 100MB!"
        else
            print_warning "⚠️  Compressed image is $(format_bytes $COMPRESSED_SIZE), which is over 100MB"
        fi
        
        print_status "To load this image elsewhere:"
        print_status "  docker load < ${OUTPUT_FILE}"
        print_status "  # or"
        print_status "  gunzip -c ${OUTPUT_FILE} | docker load"
        
    else
        print_error "Export failed!"
        exit 1
    fi
}

# Run main function
main "$@"