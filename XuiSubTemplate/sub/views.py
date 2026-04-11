from django.shortcuts import render
from django.views import View

class SubView(View):
    def get(self, request, subid):
        print(subid)
        return render(request, 'sub/SubViewPage.html')
