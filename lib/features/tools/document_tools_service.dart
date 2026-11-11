        final locations = await StorageLocationService.instance.portableDataLocations();
        final recoveryUri = locations['recoveryUri'];
        if (recoveryUri != null) {