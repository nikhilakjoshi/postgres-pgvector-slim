#!/bin/bash

# Docker Image Build Script for PostgreSQL with pgvector
# This script builds a custom PostgreSQL 15 Alpine image with pgvector extension

set -e  # Exit on any error

# Configuration
IMAGE_NAME="my-postgres-pgvector"
IMAGE_TAG="15"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

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
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -t, --tag TAG     Specify custom tag (default: 15)"
    echo "  -n, --name NAME   Specify custom image name (default: my-postgres-pgvector)"
    echo "  --no-cache        Build without using cache"
    echo "  --clean           Remove existing image before building"
    echo "  --push REGISTRY   Push to specified registry after build"
    echo ""
    echo "Examples:"
    echo "  $0                          # Build with default settings"
    echo "  $0 -t latest                # Build with 'latest' tag"
    echo "  $0 --no-cache               # Build without cache"
    echo "  $0 --clean                  # Remove existing image first"
    echo "  $0 --push docker.io/user    # Push to Docker Hub after build"
}

# Parse command line arguments
NO_CACHE=""
CLEAN_BUILD=false
PUSH_REGISTRY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -t|--tag)
            IMAGE_TAG="$2"
            FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"
            shift 2
            ;;
        -n|--name)
            IMAGE_NAME="$2"
            FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"
            shift 2
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --push)
            PUSH_REGISTRY="$2"
            shift 2
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Main build process
main() {
    print_status "Starting Docker build process..."
    print_status "Image: ${FULL_IMAGE_NAME}"
    
    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        print_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi
    
    # Check if Dockerfile exists
    if [[ ! -f "Dockerfile" ]]; then
        print_error "Dockerfile not found in current directory."
        exit 1
    fi
    
    # Clean existing image if requested
    if [[ "$CLEAN_BUILD" == true ]]; then
        print_status "Cleaning existing image..."
        if docker image inspect "$FULL_IMAGE_NAME" >/dev/null 2>&1; then
            docker rmi "$FULL_IMAGE_NAME" || print_warning "Failed to remove existing image"
        else
            print_status "No existing image found to clean."
        fi
    fi
    
    # Build the image
    print_status "Building Docker image..."
    print_status "Command: docker build ${NO_CACHE} -t ${FULL_IMAGE_NAME} ."
    
    BUILD_START_TIME=$(date +%s)
    
    if docker build ${NO_CACHE} -t "${FULL_IMAGE_NAME}" .; then
        BUILD_END_TIME=$(date +%s)
        BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
        print_success "Image built successfully in ${BUILD_DURATION} seconds!"
        
        # Show image details
        print_status "Image details:"
        docker image inspect "${FULL_IMAGE_NAME}" --format "Size: {{.Size}} bytes"
        docker image inspect "${FULL_IMAGE_NAME}" --format "Created: {{.Created}}"
        
        # Tag with latest if not already latest
        if [[ "$IMAGE_TAG" != "latest" ]]; then
            print_status "Tagging as latest..."
            docker tag "${FULL_IMAGE_NAME}" "${IMAGE_NAME}:latest"
        fi
        
        # Push to registry if specified
        if [[ -n "$PUSH_REGISTRY" ]]; then
            print_status "Pushing to registry: ${PUSH_REGISTRY}"
            REGISTRY_IMAGE="${PUSH_REGISTRY}/${FULL_IMAGE_NAME}"
            docker tag "${FULL_IMAGE_NAME}" "${REGISTRY_IMAGE}"
            
            if docker push "${REGISTRY_IMAGE}"; then
                print_success "Image pushed successfully to ${REGISTRY_IMAGE}"
            else
                print_error "Failed to push image to registry"
                exit 1
            fi
        fi
        
    else
        print_error "Docker build failed!"
        exit 1
    fi
    
    print_success "Build process completed!"
    print_status "You can now use the image with: docker run -d ${FULL_IMAGE_NAME}"
    print_status "Or update your docker-compose.yml to use: image: ${FULL_IMAGE_NAME}"
}

# Run main function
main "$@"