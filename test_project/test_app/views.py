from django.http import HttpResponse
from django.shortcuts import render

# Create your views here.
def test(request):
    return HttpResponse("It`s work after GitHub Actions!")