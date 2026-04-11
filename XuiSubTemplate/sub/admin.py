from django.contrib import admin
from .models import ClientUsageSnapshot


class ClientUsageSnapshotAdmin(admin.ModelAdmin):
    search_fields = ['email', 'subid', 'recorded_at']
    list_display = ['email', 'subid', 'recorded_at']


admin.site.register(ClientUsageSnapshot, ClientUsageSnapshotAdmin)
