import os
import subprocess
from PIL import Image, ImageDraw

def create_base_icon(size):
    # Création d'une image avec fond arrondi (style macOS)
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # Dimensions pour les coins arrondis
    padding = int(size * 0.05)
    radius = int(size * 0.22)
    box = [padding, padding, size - padding, size - padding]
    
    # Fond de l'icône (Teinte sombre style PluginLens #1b2024 avec accent turquoise #1f6f6b)
    draw.rounded_rectangle(box, radius=radius, fill="#1b2024", outline="#2d353a", width=max(1, int(size * 0.015)))
    
    # Dessin d'un motif Flat Design symbolisant des blocs de code / plugins empilés
    accent_color = "#5fc0b8"
    mut_color = "#6b767d"
    
    # Bloc supérieur
    bx1, by1 = int(size * 0.25), int(size * 0.30)
    bx2, by2 = int(size * 0.75), int(size * 0.45)
    draw.rounded_rectangle([bx1, by1, bx2, by2], radius=int(size * 0.05), fill=accent_color)
    
    # Bloc inférieur
    bx3, by3 = int(size * 0.25), int(size * 0.55)
    bx4, by4 = int(size * 0.75), int(size * 0.70)
    draw.rounded_rectangle([bx3, by3, bx4, by4], radius=int(size * 0.05), fill=mut_color)
    
    return img

def generate_icns():
    iconset_dir = "/tmp/PluginLens.iconset"
    os.makedirs(iconset_dir, exist_ok=True)
    
    # Tailles requises par macOS pour un .iconset complet
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    
    print("Génération des différentes résolutions d'icônes...")
    for s in sizes:
        # Version standard
        img = create_base_icon(s)
        img.save(os.path.join(iconset_dir, f"icon_{s}x{s}.png"))
        
        # Version Retina (@2x) si applicable
        if s <= 512:
            img_2x = create_base_icon(s * 2)
            img_2x.save(os.path.join(iconset_dir, f"icon_{s}x{s}@2x.png"))
            
    print("Conversion au format natif .icns via l'outil système macOS...")
    subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "icon.icns")], check=True)
    
    # Nettoyage du dossier temporaire
    import shutil
    shutil.rmtree(iconset_dir)
    print("Succès ! Fichier 'PluginLens.icns' généré et prêt à l'emploi.")

if __name__ == "__main__":
    try:
        generate_icns()
    except Exception as e:
        print(f"Erreur : {e}. Assurez-vous d'avoir installé Pillow (pip install Pillow).")