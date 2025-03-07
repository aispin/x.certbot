#!/bin/bash

# This script is called by certbot after successful certificate renewal
# $RENEWED_LINEAGE contains the path to the renewed certificate

echo "Certificate renewal successful for $RENEWED_LINEAGE"

# Certificate target directory (can be overridden via CERT_OUTPUT_DIR environment variable)
CERT_OUTPUT_DIR=${CERT_OUTPUT_DIR:-"/etc/letsencrypt/certs"}

# Create destination directory if it doesn't exist
mkdir -p "$CERT_OUTPUT_DIR"

# Get domain name from certificate (for domain-specific directories if needed)
if [ "$CREATE_DOMAIN_DIRS" == "true" ]; then
    # Extract domain from certificate directory name
    DOMAIN=$(basename "$RENEWED_LINEAGE")
    DOMAIN_DIR="$CERT_OUTPUT_DIR/$DOMAIN"
    mkdir -p "$DOMAIN_DIR"
    OUTPUT_DIR="$DOMAIN_DIR"
    echo "Storing certificates in domain-specific directory: $OUTPUT_DIR"
else
    OUTPUT_DIR="$CERT_OUTPUT_DIR"
    echo "Storing certificates in common directory: $OUTPUT_DIR"
fi

# Certificate file names (can be customized via environment variables)
FULLCHAIN_NAME=${FULLCHAIN_NAME:-"fullchain.pem"}
PRIVKEY_NAME=${PRIVKEY_NAME:-"privkey.pem"}
CERT_NAME=${CERT_NAME:-"cert.pem"}
CHAIN_NAME=${CHAIN_NAME:-"chain.pem"}

# Copy all certificate files to the output directory
echo "Copying certificates from $RENEWED_LINEAGE to $OUTPUT_DIR"
cp -L "$RENEWED_LINEAGE/fullchain.pem" "$OUTPUT_DIR/$FULLCHAIN_NAME"
cp -L "$RENEWED_LINEAGE/privkey.pem" "$OUTPUT_DIR/$PRIVKEY_NAME"
cp -L "$RENEWED_LINEAGE/cert.pem" "$OUTPUT_DIR/$CERT_NAME"
cp -L "$RENEWED_LINEAGE/chain.pem" "$OUTPUT_DIR/$CHAIN_NAME"

# Set proper permissions
chmod ${CERT_FILE_PERMISSIONS:-644} "$OUTPUT_DIR"/*.pem

# Create a metadata file with information about the certificate
if [ "$CREATE_METADATA" == "true" ]; then
    METADATA_FILE="$OUTPUT_DIR/metadata.json"
    echo "Creating metadata file: $METADATA_FILE"
    
    # Extract information from certificate
    CERT_SUBJECT=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -subject)
    CERT_ISSUER=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -issuer)
    CERT_DATES=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -dates)
    CERT_FINGERPRINT=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -fingerprint)
    
    # Create JSON metadata
    cat > "$METADATA_FILE" <<EOL
{
  "domain": "$(basename "$RENEWED_LINEAGE")",
  "renewed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "certificate": {
    "subject": "$CERT_SUBJECT",
    "issuer": "$CERT_ISSUER",
    "dates": "$CERT_DATES",
    "fingerprint": "$CERT_FINGERPRINT"
  },
  "files": {
    "fullchain": "$OUTPUT_DIR/$FULLCHAIN_NAME",
    "privkey": "$OUTPUT_DIR/$PRIVKEY_NAME",
    "cert": "$OUTPUT_DIR/$CERT_NAME",
    "chain": "$OUTPUT_DIR/$CHAIN_NAME"
  }
}
EOL
    chmod ${CERT_FILE_PERMISSIONS:-644} "$METADATA_FILE"
fi

# Execute host-side post-renewal script if configured
# Check custom script path first
if [ -n "$POST_RENEWAL_SCRIPT" ] && [ -f "$POST_RENEWAL_SCRIPT" ] && [ -x "$POST_RENEWAL_SCRIPT" ]; then
    echo "Executing custom post-renewal script: $POST_RENEWAL_SCRIPT"
    
    # Pass certificate details to the script as environment variables
    RENEWED_DOMAIN=$(basename "$RENEWED_LINEAGE") \
    RENEWED_FULLCHAIN="$OUTPUT_DIR/$FULLCHAIN_NAME" \
    RENEWED_PRIVKEY="$OUTPUT_DIR/$PRIVKEY_NAME" \
    RENEWED_CERT="$OUTPUT_DIR/$CERT_NAME" \
    RENEWED_CHAIN="$OUTPUT_DIR/$CHAIN_NAME" \
    "$POST_RENEWAL_SCRIPT"
    
    echo "Custom post-renewal script executed with exit code: $?"
# Fall back to default location
elif [ -f "/host-scripts/post-renewal.sh" ] && [ -x "/host-scripts/post-renewal.sh" ]; then
    echo "Executing host post-renewal script..."
    
    # Pass certificate details to the script as environment variables
    RENEWED_DOMAIN=$(basename "$RENEWED_LINEAGE") \
    RENEWED_FULLCHAIN="$OUTPUT_DIR/$FULLCHAIN_NAME" \
    RENEWED_PRIVKEY="$OUTPUT_DIR/$PRIVKEY_NAME" \
    RENEWED_CERT="$OUTPUT_DIR/$CERT_NAME" \
    RENEWED_CHAIN="$OUTPUT_DIR/$CHAIN_NAME" \
    /host-scripts/post-renewal.sh
    
    echo "Host post-renewal script executed with exit code: $?"
else
    echo "No executable post-renewal script found"
fi

# Send webhook notification if configured
if [ -n "$WEBHOOK_URL" ]; then
    echo "Sending webhook notification to $WEBHOOK_URL"
    
    # Prepare webhook data
    WEBHOOK_DATA="{\"domain\":\"$(basename "$RENEWED_LINEAGE")\",\"status\":\"success\",\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}"
    
    # Send webhook request
    curl -s -X POST -H "Content-Type: application/json" -d "$WEBHOOK_DATA" "$WEBHOOK_URL"
    
    if [ $? -eq 0 ]; then
        echo "Webhook notification sent successfully"
    else
        echo "Failed to send webhook notification"
    fi
fi

echo "Deploy hook completed successfully"