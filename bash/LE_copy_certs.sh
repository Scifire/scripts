#!/bin/sh
set -e

# This script can be placed in /etc/letsencrypt/renewal-hooks/deploy so it is
# automatically executed after a successful certificate renewal.
# It will copy fullchain.pem and privkey.pem (or all .pem files) to the
# destination if the target domain matches the renewed certificate.
# It will also change permissions for privkey.pem in the Destination to be reabable for everyone (unsecure!).


DEST_DIR="/some/folder"
TARGET_DOAMIN="*.domain.example" 
TARGET_FOLDER="domain.example" #LE does not add * to folder name

echo "Renewal hook running to copy certificate and private key to appropriate directory..."
echo "RENEWED_DOMAINS=$RENEWED_DOMAINS"

for DOMAIN in $RENEWED_DOMAINS ; do
  if [ "$DOMAIN" = "$TARGET_DOAMIN" ] ; then
    cp -f -p /etc/letsencrypt/live/giatamedia.com/fullchain.pem $DEST_DIR
    cp -f -p /etc/letsencrypt/live/giatamedia.com/privkey.pem $DEST_DIR
    #find -L "/etc/letsencrypt/live/$TARGET_FOLDER" -type f -name "*.pem" | xargs -r cp -v --target "$DEST_DIR" # Use this is case all certificates and keys are required
    chmod 0644 "$DEST_DIR/privkey.pem"  #This is unsafe and not recommended
    echo "Done copying certificates and private key"

  fi
done
